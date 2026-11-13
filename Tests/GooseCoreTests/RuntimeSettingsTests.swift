import Foundation
import XCTest
@testable import GooseCore

final class RuntimeSettingsTests: XCTestCase {
    func testOlderShortcutsAndDXMTSettingsKeepTheirBehavior() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id)","name":"CoD4","executablePath":"/games/iw3sp.exe","arguments":["+set","r_vsync","0"]}
        """.utf8)
        let app = try JSONDecoder().decode(SavedApplication.self, from: data)
        XCTAssertEqual(app.id, id)
        XCTAssertFalse(app.isFavorite)
        XCTAssertEqual(app.arguments, ["+set", "r_vsync", "0"])
        let options = try JSONDecoder().decode(DXMTOptions.self, from: Data(#"{"metalHUD":true,"maximumFrameRate":144}"#.utf8))
        XCTAssertTrue(options.metalHUD)
        XCTAssertEqual(options.maximumFrameRate, 144)
        XCTAssertTrue(options.shaderCache)
        XCTAssertTrue(options.asyncPipelineCompilation)
        XCTAssertFalse(DXMTOptions().asyncPipelineCompilation)
    }

    func testGlobalX87MathAppliesToApplicationsAndCanBeDisabled() throws {
        let app = SavedApplication(name: "CS", executablePath: "/games/hl.exe", arguments: ["-game", "cstrike"])
        XCTAssertEqual(try JSONDecoder().decode(SavedApplication.self, from: JSONEncoder().encode(app)), app)
        let bottle = Bottle(name: "Games")
        let layout = EngineLayout(root: URL(fileURLWithPath: "/bundled-engines"), environment: [:])
        let prefix = URL(fileURLWithPath: "/owned-prefix")
        let fast = ProcessInvocation.application(bottle: bottle, prefix: prefix,
            executable: URL(fileURLWithPath: app.executablePath), arguments: app.arguments,
            engines: layout, inherited: [:])
        XCTAssertEqual(fast.environment["FEX_X87REDUCEDPRECISION"], "1")
        let other = ProcessInvocation.application(bottle: bottle, prefix: prefix,
            executable: URL(fileURLWithPath: "/games/other.exe"), arguments: [],
            engines: layout, inherited: fast.environment)
        XCTAssertEqual(other.environment["FEX_X87REDUCEDPRECISION"], "1")
        let precise = ProcessInvocation.application(bottle: bottle, prefix: prefix,
            executable: URL(fileURLWithPath: "/games/other.exe"), arguments: [],
            engines: layout, inherited: fast.environment, settings: RuntimeSettings(reducedX87Precision: false))
        XCTAssertEqual(precise.environment["FEX_X87REDUCEDPRECISION"], "0")
        let tool = RuntimeEnvironment.build(bottle: bottle, prefix: prefix, engines: layout,
                                            inherited: fast.environment, initialize: true)
        XCTAssertNil(tool["FEX_X87REDUCEDPRECISION"])
        let rosetta = ProcessInvocation.application(bottle: Bottle(name: "Rosetta", architecture: .x64), prefix: prefix,
            executable: URL(fileURLWithPath: app.executablePath), arguments: [], engines: layout, inherited: fast.environment)
        XCTAssertNil(rosetta.environment["FEX_X87REDUCEDPRECISION"])
        XCTAssertEqual(fast.arguments, [app.executablePath] + app.arguments)
    }

    func testOpenGLBatchingUsesGlobalModuleAndCompatibilityFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["i386-windows/opengl32.dll", "aarch64-unix/opengl32.so"] {
            let file = root.appendingPathComponent("LegacyOpenGL/" + name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: file)
        }
        let layout = EngineLayout(root: root, environment: [:])
        let prefix = URL(fileURLWithPath: "/owned-prefix")
        let bottle = Bottle(name: "Games")
        let fast = ProcessInvocation.application(bottle: bottle, prefix: prefix,
            executable: URL(fileURLWithPath: "/games/any-game.exe"), arguments: [], engines: layout, inherited: [:])
        XCTAssertEqual(fast.environment["WINE_GL_BATCHING_PATH"], layout.legacyOpenGL.path)
        XCTAssertEqual(fast.environment["WINE_GL_BATCHING"], "1")
        XCTAssertEqual(fast.environment["WINEDLLPATH"], layout.dllRoot(.arm64ec).path)
        let off = ProcessInvocation.application(bottle: bottle, prefix: prefix,
            executable: URL(fileURLWithPath: "/games/other.exe"), arguments: [], engines: layout,
            inherited: fast.environment, settings: RuntimeSettings(legacyOpenGLBatching: false))
        XCTAssertNil(off.environment["WINE_GL_BATCHING_PATH"])
        XCTAssertNil(off.environment["WINE_GL_BATCHING"])
        let tool = RuntimeEnvironment.build(bottle: bottle, prefix: prefix, engines: layout, inherited: fast.environment)
        XCTAssertNil(tool["WINE_GL_BATCHING_PATH"])
        XCTAssertNil(tool["WINE_GL_BATCHING"])
        let x64 = ProcessInvocation.application(bottle: Bottle(name: "Rosetta", architecture: .x64), prefix: prefix,
            executable: URL(fileURLWithPath: "/games/other.exe"), arguments: [], engines: layout, inherited: fast.environment)
        XCTAssertNil(x64.environment["WINE_GL_BATCHING_PATH"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("LegacyOpenGL/i386-windows/opengl32.dll"))
        let missing = ProcessInvocation.application(bottle: bottle, prefix: prefix,
            executable: URL(fileURLWithPath: "/games/other.exe"), arguments: [], engines: layout, inherited: [:])
        XCTAssertNil(missing.environment["WINE_GL_BATCHING_PATH"])
        let old = try JSONDecoder().decode(RuntimeSettings.self, from: Data(#"{"reducedX87Precision":false}"#.utf8))
        XCTAssertFalse(old.reducedX87Precision)
        XCTAssertTrue(old.legacyOpenGLBatching)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeSettings.self, from: JSONEncoder().encode(old)), old)
    }

    func testGlobalRuntimeSettingsPersistAcrossServicesAndShortcutEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = SavedApplication(name: "CS", executablePath: "/games/hl.exe")
        let bottle = Bottle(name: "Games", applications: [app])
        let store = BottleStore(root: root)
        try store.reserve(bottle)
        let service = HubService(dataRoot: root, environment: [:])
        let defaults = try await service.runtimeSettings()
        XCTAssertTrue(defaults.reducedX87Precision)
        try await service.updateRuntimeSettings(RuntimeSettings(reducedX87Precision: false))
        let restarted = HubService(dataRoot: root, environment: [:])
        let persisted = try await restarted.runtimeSettings()
        XCTAssertFalse(persisted.reducedX87Precision)
        _ = try await service.updateApplication(bottleID: bottle.id, applicationID: app.id,
                                                name: "Counter-Strike", arguments: ["-gl"])
        XCTAssertEqual(try store.load(bottle.id).applications[0].arguments, ["-gl"])
        XCTAssertFalse(try store.runtimeSettings().reducedX87Precision)
        try await restarted.updateRuntimeSettings(RuntimeSettings(reducedX87Precision: true))
        let enabled = try await service.runtimeSettings()
        XCTAssertTrue(enabled.reducedX87Precision)
        XCTAssertTrue(try JSONDecoder().decode(RuntimeSettings.self, from: Data("{}".utf8)).reducedX87Precision)
    }

    func testSettingsRoundTripAndOverrideUntrustedInheritedOptions() throws {
        let options = DXMTOptions(metalHUD: true, maximumFrameRate: 120, shaderCache: false, asyncPipelineCompilation: false)
        XCTAssertEqual(try JSONDecoder().decode(DXMTOptions.self, from: JSONEncoder().encode(options)), options)
        let bottle = Bottle(name: "Games", dxmt: options)
        let layout = EngineLayout(root: URL(fileURLWithPath: "/bundled-engines"), environment: [:])
        let environment = RuntimeEnvironment.build(bottle: bottle, prefix: URL(fileURLWithPath: "/owned-prefix"), engines: layout,
            inherited: ["DXMT_CONFIG": "d3d11.preferredMaxFrameRate=1", "DXMT_SHADER_CACHE": "1", "WINEMSYNC": "0"])
        XCTAssertEqual(environment["DXMT_CONFIG"], "d3d11.asyncPipelineCompilation=False;d3d11.preferredMaxFrameRate=120")
        XCTAssertEqual(environment["DXMT_SHADER_CACHE"], "0")
        XCTAssertEqual(environment["WINEMSYNC"], "1")
        XCTAssertEqual(environment["MTL_HUD_ENABLED"], "1")
        var fallback = bottle
        fallback.renderer = .wined3d
        let fallbackEnvironment = RuntimeEnvironment.build(bottle: fallback, prefix: URL(fileURLWithPath: "/owned-prefix"), engines: layout, inherited: environment)
        XCTAssertNil(fallbackEnvironment["DXMT_CONFIG"])
        XCTAssertNil(fallbackEnvironment["DXMT_SHADER_CACHE"])
    }

    func testFavoriteIsPersistedWithoutChangingOtherShortcutMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = SavedApplication(name: "CoD4", executablePath: "/games/iw3sp.exe", arguments: ["+set", "r_vsync", "0"])
        let bottle = Bottle(name: "Games", applications: [app])
        let store = BottleStore(root: root)
        try store.reserve(bottle)
        let service = HubService(dataRoot: root, environment: [:])
        _ = try await service.setApplicationFavorite(bottleID: bottle.id, applicationID: app.id, isFavorite: true)
        let updated = try store.load(bottle.id)
        XCTAssertTrue(updated.applications[0].isFavorite)
        XCTAssertEqual(updated.applications[0].id, app.id)
        XCTAssertEqual(updated.applications[0].executablePath, app.executablePath)
        XCTAssertEqual(updated.applications[0].arguments, app.arguments)
        _ = try await service.setApplicationFavorite(bottleID: bottle.id, applicationID: app.id, isFavorite: false)
        XCTAssertFalse(try store.load(bottle.id).applications[0].isFavorite)
    }

    func testLogTailIsBoundedAndRejectsLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(name: "Logs")
        let store = BottleStore(root: root)
        try store.reserve(bottle)
        let launchID = UUID()
        let log = try store.logURL(bottle.id, id: launchID)
        try Data((String(repeating: "old output\n", count: 40_000) + "FINAL LINE\n").utf8).write(to: log)
        let service = HubService(dataRoot: root, environment: [:])
        let output = try await service.readLaunchLog(bottleID: bottle.id, launchID: launchID, maximumBytes: 4096)
        XCTAssertTrue(output.hasPrefix("[Showing the end of this log]\n"))
        XCTAssertTrue(output.hasSuffix("FINAL LINE\n"))
        XCTAssertLessThan(output.utf8.count, 4200)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(atPath: log.path, withDestinationPath: "/etc/hosts")
        do {
            _ = try await service.readLaunchLog(bottleID: bottle.id, launchID: launchID)
            XCTFail("A symbolic link must not be read as an owned session log")
        } catch { XCTAssertTrue(error is HubError) }
    }

    func testEngineVersionsDescribeBundledManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("manifest.json")
        try Data(#"{"wine":{"version":"11.20"},"dxmt":{"version":"Adrenalin 2026.10.28","commit":"old-base"},"fex":{"commit":"1234567890abcdef"},"sourceReviewDate":"2026-10-28","assets":[]}"#.utf8).write(to: manifest)
        let versions = try XCTUnwrap(EngineVersions.read(from: manifest))
        XCTAssertEqual(versions.wine, "11.20")
        XCTAssertEqual(versions.dxmt, "Adrenalin 2026.10.28")
        XCTAssertEqual(versions.fex, "1234567890")
        XCTAssertEqual(versions.reviewedAt, "2026-10-28")
        try Data("invalid".utf8).write(to: manifest)
        XCTAssertNil(EngineVersions.read(from: manifest))
    }
}
