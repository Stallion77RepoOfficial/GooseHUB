import Foundation
import XCTest
@testable import GooseCore

final class InstallerCompatibilityTests: XCTestCase {
    private func invocation(_ executable: URL, fast: Bool = true) -> ProcessInvocation {
        ProcessInvocation.application(bottle: Bottle(name: "Applications"),
            prefix: URL(fileURLWithPath: "/owned-prefix"), executable: executable, arguments: [],
            engines: EngineLayout(root: URL(fileURLWithPath: "/engines"), environment: [:]),
            inherited: ["FEX_X87REDUCEDPRECISION": "1"], settings: RuntimeSettings(reducedX87Precision: fast))
    }

    func testInstallerPrecisionDoesNotDisableGlobalGameAcceleration() {
        for name in ["setup.exe", "SETUP.EXE", "install.exe", "installer.exe", "uninstall.exe", "unins000.exe", "package.msi"] {
            let result = invocation(URL(fileURLWithPath: "/downloads/" + name))
            XCTAssertEqual(result.environment["FEX_X87REDUCEDPRECISION"], "0", name)
        }
        for name in ["hl.exe", "iw3sp.exe", "GameSetupSimulator.exe", "uninstalled-game.exe"] {
            XCTAssertEqual(invocation(URL(fileURLWithPath: "/games/" + name)).environment["FEX_X87REDUCEDPRECISION"], "1", name)
        }
        XCTAssertEqual(invocation(URL(fileURLWithPath: "/games/hl.exe"), fast: false)
            .environment["FEX_X87REDUCEDPRECISION"], "0")
        let msi = invocation(URL(fileURLWithPath: "/downloads/with spaces/package.msi"))
        XCTAssertEqual(msi.arguments, ["msiexec", "/i", "/downloads/with spaces/package.msi"])
        XCTAssertEqual(msi.workingDirectory.path, "/downloads/with spaces")
    }

    func testRenamedInstallerSignaturesAndUnrelatedExecutableContents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("AcmeRelease.exe")
        func header(_ marker: String) -> Data {
            var data = Data(repeating: 0, count: 256)
            data[0] = 0x4d; data[1] = 0x5a; data[60] = 128
            data.replaceSubrange(128..<132, with: [0x50, 0x45, 0, 0])
            data.append(Data(marker.utf8))
            return data
        }
        for marker in ["Inno Setup Setup Data (5.5.0) (u)", "Inno Setup Uninstall Log", "NullsoftInst"] {
            try header(marker).write(to: executable)
            XCTAssertEqual(invocation(executable).environment["FEX_X87REDUCEDPRECISION"], "0", marker)
        }
        try header("This game mentions setup.exe in its help.").write(to: executable)
        XCTAssertEqual(invocation(executable).environment["FEX_X87REDUCEDPRECISION"], "1")
        // A truncated or invalid PE header must not crash the launch planner.
        for data in [Data(), Data([0x4d, 0x5a]), Data(repeating: 255, count: 64), Data("Inno Setup Setup Data".utf8)] {
            try data.write(to: executable)
            XCTAssertEqual(invocation(executable).environment["FEX_X87REDUCEDPRECISION"], "1")
        }
    }
}
