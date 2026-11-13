import Foundation
import XCTest
@testable import GooseCore

final class EngineInstallationTests: XCTestCase {
    func testCompleteSourceBuildLayoutDoesNotRequireDuplicateWineWrappers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var files = ["Wine/bin/wine", "Wine/bin/wineserver",
                     "Wine/lib/wine/aarch64-windows/xtajit64.dll", "Wine/lib/wine/aarch64-windows/xtajit.dll",
                     "Wine/lib/wine/aarch64-unix/libarm64ecfex.so", "Wine/lib/wine/aarch64-unix/libwow64fex.so",
                     "Wine/lib/wine/aarch64-unix/winemetal.so", "MetalGoose/bin/metalgoose-backend",
                     "Vulkan/icd.d/MoltenVK_icd.json", "Dependencies/arm64/libMoltenVK.dylib"]
        // This is the real source build's DXMT layout. The D3D10/10.1 wrappers live in Wine.
        for arch in ["arm64ec", "x86"] {
            for dll in ["d3d8", "d3d9", "d3d10core", "d3d11", "d3d12", "dxgi", "winemetal"] {
                files.append("DXMT/\(arch)/\(dll).dll")
            }
        }
        for name in files {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let inf = root.appendingPathComponent("Wine/share/wine/wine.inf")
        try FileManager.default.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[Version]\n".utf8).write(to: inf)
        try Data(#"{"schemaVersion":2,"installationComplete":true}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        let status = EngineLayout(root: root, environment: [:]).status()
        XCTAssertTrue(status.isUsable, status.issues.joined(separator: "; "))
    }

    func testIncompleteInstallationDoesNotCreateABottle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = directory.appendingPathComponent("data")
        let service = HubService(dataRoot: data, enginesRoot: directory.appendingPathComponent("Engines"), environment: [:])
        do {
            _ = try await service.createBottle(name: "Games")
            XCTFail("An incomplete engine installation must not create a bottle")
        } catch HubError.engineUnavailable(let reason) {
            XCTAssertTrue(reason.contains("installation"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("Bottles").path))
    }
}
