import Foundation
import XCTest
@testable import GooseCore

final class DXMTUpgradeTests: XCTestCase {
    private func fixture(_ root: URL) throws -> (Bottle, URL, URL, EngineLayout) {
        let fm = FileManager.default
        let directory = root.appendingPathComponent("Bottle")
        let prefix = directory.appendingPathComponent("prefix")
        let engines = EngineLayout(root: root.appendingPathComponent("Engines"), environment: [:])
        for (source, destination) in [("arm64ec", "system32"), ("x86", "syswow64")] {
            try fm.createDirectory(at: engines.dxmtDirectory(source), withIntermediateDirectories: true)
            try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/\(destination)"), withIntermediateDirectories: true)
            for dll in DXMTDeployment.libraries {
                try Data("DXMT-1-\(source)-\(dll)".utf8).write(to: engines.dxmtDirectory(source).appendingPathComponent(dll))
                try Data("original-\(destination)-\(dll)".utf8).write(to: prefix.appendingPathComponent("drive_c/windows/\(destination)/\(dll)"))
            }
        }
        let bridge = engines.root.appendingPathComponent("Wine/lib/wine/aarch64-unix/winemetal.so")
        try fm.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: bridge)
        return (Bottle(name: "Games"), directory, prefix, engines)
    }

    func testWineBootstrapCopiesOfCurrentDLLsRefreshOwnershipWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, directory, prefix, engines) = try fixture(root)
        try DXMTDeployment.install(bottle: bottle, directory: directory, prefix: prefix, engines: engines)
        var identities: [String: UInt64] = [:]
        for (source, destination) in [("arm64ec", "system32"), ("x86", "syswow64")] {
            let current = prefix.appendingPathComponent("drive_c/windows/\(destination)/winemetal.dll")
            let bytes = Data("DXMT-2-\(source)-winemetal".utf8)
            try bytes.write(to: engines.dxmtDirectory(source).appendingPathComponent("winemetal.dll"))
            try bytes.write(to: current)
            identities[destination] = (try FileManager.default.attributesOfItem(atPath: current.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        try DXMTDeployment.install(bottle: bottle, directory: directory, prefix: prefix, engines: engines)
        let state = try JSONFile.read(DLLDeploymentState.self, at: directory.appendingPathComponent(".goose-dxmt.json"))
        for entry in state.entries {
            XCTAssertEqual(try DXMTDeployment.fingerprint(prefix.appendingPathComponent(entry.destination)), entry.installedFingerprint)
        }
        for destination in ["system32", "syswow64"] {
            let current = prefix.appendingPathComponent("drive_c/windows/\(destination)/winemetal.dll")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: current.path)[.systemFileNumber] as? NSNumber)?.uint64Value, identities[destination])
        }
        try DXMTDeployment.restore(bottle: bottle, directory: directory, prefix: prefix)
        for destination in ["system32", "syswow64"] {
            for dll in DXMTDeployment.libraries {
                XCTAssertEqual(try Data(contentsOf: prefix.appendingPathComponent("drive_c/windows/\(destination)/\(dll)")), Data("original-\(destination)-\(dll)".utf8))
            }
        }
    }

    func testUnknownDLLChangesStillBlockDeployment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bottle, directory, prefix, engines) = try fixture(root)
        try DXMTDeployment.install(bottle: bottle, directory: directory, prefix: prefix, engines: engines)
        let manifest = directory.appendingPathComponent(".goose-dxmt.json")
        let before = try Data(contentsOf: manifest)
        let custom = prefix.appendingPathComponent("drive_c/windows/system32/winemetal.dll")
        try Data("user DLL".utf8).write(to: custom)
        XCTAssertThrowsError(try DXMTDeployment.install(bottle: bottle, directory: directory, prefix: prefix, engines: engines))
        XCTAssertEqual(try Data(contentsOf: custom), Data("user DLL".utf8))
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }
}
