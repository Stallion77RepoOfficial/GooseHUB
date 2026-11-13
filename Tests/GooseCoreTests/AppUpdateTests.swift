import Foundation
import XCTest
@testable import GooseCore

final class AppUpdateTests: XCTestCase {
    private let identifier = "dev.goosehub.adrenalin"

    private func command(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeApp(_ app: URL, version: String, id: String = "dev.goosehub.adrenalin", engines: Bool = false) throws {
        let fm = FileManager.default
        let executable = app.appendingPathComponent("Contents/MacOS/GooseHUB")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources.appendingPathComponent("Bootstrap"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": id, "CFBundleExecutable": "GooseHUB", "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": version, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.cs.allow-jit": true], format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("Bootstrap/GooseHUB.entitlements"))
        if engines {
            let root = resources.appendingPathComponent("Engines")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("custom engine bytes".utf8).write(to: root.appendingPathComponent("custom.bin"))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("linked.bin").path, withDestinationPath: "custom.bin")
        }
        try command("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }

    private func archive(_ app: URL, at zip: URL) throws {
        try command("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
    }

    func testLauncherUpdateKeepsLocallyBuiltEnginesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current.app")
        let next = root.appendingPathComponent("New.app")
        try makeApp(current, version: "0.4.0", engines: true)
        try makeApp(next, version: "0.4.1")
        let zip = root.appendingPathComponent("update.zip")
        try archive(next, at: zip)
        _ = try AppUpdateInstaller.replace(archive: zip, currentApp: current, bundleIdentifier: identifier, lockURL: root.appendingPathComponent("lock"))
        let engine = current.appendingPathComponent("Contents/Resources/Engines")
        XCTAssertEqual(try Data(contentsOf: engine.appendingPathComponent("linked.bin")), Data("custom engine bytes".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: engine.appendingPathComponent("linked.bin").path), "custom.bin")
        let data = try Data(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.4.1")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".goosehub-") })
    }

    func testInvalidUpdatesLeaveInstalledAppIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Current.app")
        try makeApp(current, version: "0.4.0", engines: true)
        let before = try Data(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
        for scenario in ["wrong-identity", "tampered", "bundled-engines"] {
            let next = root.appendingPathComponent(scenario + ".app")
            try makeApp(next, version: "0.4.1", id: scenario == "wrong-identity" ? "test.other" : identifier,
                        engines: scenario == "bundled-engines")
            if scenario == "tampered" {
                let infoURL = next.appendingPathComponent("Contents/Info.plist")
                let data = try Data(contentsOf: infoURL)
                var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
                info["CFBundleDisplayName"] = "Changed after signing"
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            }
            let zip = root.appendingPathComponent(scenario + ".zip")
            try archive(next, at: zip)
            XCTAssertThrowsError(try AppUpdateInstaller.replace(archive: zip, currentApp: current,
                bundleIdentifier: identifier, lockURL: root.appendingPathComponent("lock")))
            XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("Contents/Info.plist")), before)
            XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("Contents/Resources/Engines/custom.bin")), Data("custom engine bytes".utf8))
        }
    }

    func testReleaseOrderingMatchesMetalGoose() {
        XCTAssertGreaterThan(SemanticVersion("v0.4.1"), SemanticVersion("0.4.0"))
        XCTAssertLessThan(SemanticVersion("0.4.1-beta.1"), SemanticVersion("0.4.1"))
        XCTAssertEqual(SemanticVersion("v0.4.1+19"), SemanticVersion("0.4.1"))
        XCTAssertGreaterThan(SemanticVersion("1.2.2a"), SemanticVersion("1.2.2"))
    }
}
