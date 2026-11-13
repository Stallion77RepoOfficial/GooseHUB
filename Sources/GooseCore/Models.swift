import Foundation

public enum BottleArchitecture: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A native ARM64 Wine host. x86/x64 guest execution additionally needs FEX and host approval.
    case arm64ec
    /// Only offered when a separate x86_64 Wine engine is bundled.
    case x64

    public var id: String { rawValue }
    public var title: String { self == .arm64ec ? "ARM64 / ARM64EC" : "x64 (Rosetta)" }
}

public enum Renderer: String, Codable, CaseIterable, Sendable, Identifiable {
    case dxmt, wined3d
    public var id: String { rawValue }
    public var title: String { self == .dxmt ? "DXMT / Metal" : "WineD3D" }
}

public enum SynchronizationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case msync, none
    public var id: String { rawValue }
    public var title: String { self == .msync ? "MSync" : "Default" }
}

/// The Windows version a bottle reports, as winecfg names it. Prefixes are 64-bit, so XP is XP x64.
public enum WindowsVersion: String, Codable, CaseIterable, Sendable, Identifiable {
    case win11, win10, win81, win8, win7, winxp64
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win8: "Windows 8"
        case .win7: "Windows 7"
        case .winxp64: "Windows XP"
        }
    }
}

/// Wine's own programs, which a bottle runs like an application.
public enum WineTool: String, CaseIterable, Sendable, Identifiable {
    case configuration, controlPanel, registryEditor, taskManager, commandPrompt, uninstaller, reboot
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .configuration: "Wine Configuration"
        case .controlPanel: "Control Panel"
        case .registryEditor: "Registry Editor"
        case .taskManager: "Task Manager"
        case .commandPrompt: "Command Prompt"
        case .uninstaller: "Uninstall Programs"
        case .reboot: "Simulate Reboot"
        }
    }
    /// A reboot closes the bottle's programs, then runs what installers left to run at startup.
    var command: [String] {
        switch self {
        case .configuration: ["winecfg"]
        case .controlPanel: ["control"]
        case .registryEditor: ["regedit"]
        case .taskManager: ["taskmgr"]
        case .commandPrompt: ["wineconsole", "cmd"]
        case .uninstaller: ["uninstaller"]
        case .reboot: ["wineboot", "--end-session", "--force", "--kill"]
        }
    }
}

public enum BottleState: String, Codable, Sendable { case creating, ready }

public struct DXMTOptions: Codable, Equatable, Sendable {
    public var metalHUD: Bool
    public var maximumFrameRate: Int?
    public var shaderCache: Bool
    public var asyncPipelineCompilation: Bool

    public init(metalHUD: Bool = false, maximumFrameRate: Int? = nil,
                shaderCache: Bool = true, asyncPipelineCompilation: Bool = false) {
        self.metalHUD = metalHUD
        self.maximumFrameRate = maximumFrameRate
        self.shaderCache = shaderCache
        self.asyncPipelineCompilation = asyncPipelineCompilation
    }

    enum CodingKeys: String, CodingKey { case metalHUD, maximumFrameRate, shaderCache, asyncPipelineCompilation }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metalHUD = try values.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        maximumFrameRate = try values.decodeIfPresent(Int.self, forKey: .maximumFrameRate)
        shaderCache = try values.decodeIfPresent(Bool.self, forKey: .shaderCache) ?? true
        // Existing bottles keep their previous pipeline behavior. New bottles wait
        // for compilation so a cold cache cannot make geometry disappear.
        asyncPipelineCompilation = try values.decodeIfPresent(Bool.self, forKey: .asyncPipelineCompilation) ?? true
    }
}

/// Whether Goose HUB attaches MetalGoose to the games a bottle starts. MetalGoose's settings stay
/// with MetalGoose, one set for every game, as in its app.
public struct MetalGooseSettings: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = false) { self.enabled = enabled }

    enum CodingKeys: String, CodingKey { case enabled }

    /// Bottles saved with MetalGoose's settings of their own keep only the switch.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

public struct RuntimeSettings: Codable, Equatable, Sendable {
    public var reducedX87Precision: Bool
    public var legacyOpenGLBatching: Bool

    public init(reducedX87Precision: Bool = true, legacyOpenGLBatching: Bool = true) {
        self.reducedX87Precision = reducedX87Precision
        self.legacyOpenGLBatching = legacyOpenGLBatching
    }

    enum CodingKeys: String, CodingKey { case reducedX87Precision, legacyOpenGLBatching }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reducedX87Precision = try values.decodeIfPresent(Bool.self, forKey: .reducedX87Precision) ?? true
        legacyOpenGLBatching = try values.decodeIfPresent(Bool.self, forKey: .legacyOpenGLBatching) ?? true
    }
}

public struct SavedApplication: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var executablePath: String
    public var arguments: [String]
    public var isFavorite: Bool

    public init(id: UUID = UUID(), name: String, executablePath: String, arguments: [String] = [], isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.isFavorite = isFavorite
    }

    enum CodingKeys: String, CodingKey { case id, name, executablePath, arguments, isFavorite }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        executablePath = try values.decode(String.self, forKey: .executablePath)
        arguments = try values.decode([String].self, forKey: .arguments)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

public struct Bottle: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let architecture: BottleArchitecture
    public var renderer: Renderer
    public var synchronization: SynchronizationMode
    public let createdAt: Date
    public var updatedAt: Date
    public var applications: [SavedApplication]
    public var dxmt: DXMTOptions
    public var metalGoose: MetalGooseSettings
    public var debugLogging: Bool
    public var windowsVersion: WindowsVersion
    /// Wine's Retina mode: programs draw at the display's full pixel resolution.
    public var highResolution: Bool
    public internal(set) var state: BottleState

    public init(id: UUID = UUID(), name: String, architecture: BottleArchitecture = .arm64ec,
                renderer: Renderer = .dxmt, synchronization: SynchronizationMode = .msync,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                applications: [SavedApplication] = [], dxmt: DXMTOptions = DXMTOptions(),
                metalGoose: MetalGooseSettings = MetalGooseSettings(),
                debugLogging: Bool = false, windowsVersion: WindowsVersion = .win10,
                highResolution: Bool = false, state: BottleState = .ready) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.renderer = renderer
        self.synchronization = synchronization
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.applications = applications
        self.dxmt = dxmt
        self.metalGoose = metalGoose
        self.debugLogging = debugLogging
        self.windowsVersion = windowsVersion
        self.highResolution = highResolution
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case id, name, architecture, renderer, synchronization, createdAt, updatedAt, applications, dxmt
        case metalGoose, debugLogging, windowsVersion, highResolution, state
    }

    /// Bottles saved before MetalGoose had settings of its own get MetalGoose's defaults, switched off.
    /// Older bottles have Wine's defaults: Windows 10, Retina mode off.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        architecture = try values.decode(BottleArchitecture.self, forKey: .architecture)
        renderer = try values.decode(Renderer.self, forKey: .renderer)
        synchronization = try values.decode(SynchronizationMode.self, forKey: .synchronization)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        applications = try values.decode([SavedApplication].self, forKey: .applications)
        dxmt = try values.decode(DXMTOptions.self, forKey: .dxmt)
        metalGoose = try values.decodeIfPresent(MetalGooseSettings.self, forKey: .metalGoose) ?? MetalGooseSettings()
        debugLogging = try values.decode(Bool.self, forKey: .debugLogging)
        windowsVersion = try values.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? .win10
        highResolution = try values.decodeIfPresent(Bool.self, forKey: .highResolution) ?? false
        state = try values.decode(BottleState.self, forKey: .state)
    }
}

public enum LaunchStatus: String, Codable, Sendable { case running, exited, failed, interrupted }

public struct LaunchRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let bottleID: UUID
    public let executablePath: String
    public let arguments: [String]
    public let startedAt: Date
    public var endedAt: Date?
    public var processIdentifier: Int32
    public var status: LaunchStatus
    public var exitCode: Int32?
    public let logPath: String
}

public struct EngineStatus: Codable, Equatable, Sendable {
    public let rootPath: String
    public let wineAvailable: Bool
    public let wineX64Available: Bool
    public let dxmtAvailable: Bool
    public let metalGooseAvailable: Bool
    public let fexAvailable: Bool
    public let vulkanAvailable: Bool
    public let issues: [String]
    public let summary: String
    public let versions: EngineVersions?

    public var isUsable: Bool {
        wineAvailable && dxmtAvailable && fexAvailable && metalGooseAvailable && vulkanAvailable && issues.isEmpty
    }
}

public enum HubError: Error, LocalizedError, Sendable {
    case invalidName
    case invalidArguments
    case engineUnavailable(String)
    case invalidExecutable(String)
    case unsafePath(String)
    case invalidMetadata(String)
    case bottleNotFound(UUID)
    case bottleBusy(UUID)
    case architectureCannotChange
    case prefixInitializationFailed(Int32, String)
    case processFailed(String)
    case processTimedOut(String)
    case deploymentFailed(String)
    case applicationNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Use a name containing 1–128 characters without control characters."
        case .invalidArguments: "Arguments must not contain NUL characters or exceed the launch limit."
        case .engineUnavailable(let detail): "Engine unavailable: \(detail)"
        case .invalidExecutable(let path): "Select an existing Windows .exe or .msi file: \(path)"
        case .unsafePath(let detail): "Refusing an unsafe path: \(detail)"
        case .invalidMetadata(let detail): "Bottle metadata needs attention: \(detail)"
        case .bottleNotFound(let id): "Bottle not found: \(id.uuidString)"
        case .bottleBusy: "Stop this bottle’s running applications first."
        case .architectureCannotChange: "An existing bottle’s architecture cannot be changed. Create another bottle."
        case .prefixInitializationFailed(let code, let log): "Wine initialization failed (\(code)). Log: \(log)"
        case .processFailed(let detail): "Could not run Wine: \(detail)"
        case .processTimedOut(let detail): "Wine timed out: \(detail)"
        case .deploymentFailed(let detail): "DXMT deployment failed: \(detail)"
        case .applicationNotFound(let id): "Application shortcut not found: \(id.uuidString)"
        }
    }
}

struct BottleDocument: Codable {
    var schemaVersion = 1
    var bottle: Bottle
}

struct OwnershipMarker: Codable {
    let schemaVersion: Int
    let application: String
    let bottleID: UUID
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try PathGuard.requireRegularFile(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: Data(contentsOf: url)) }
        catch { throw HubError.invalidMetadata("\(url.path): \(error.localizedDescription)") }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try PathGuard.rejectSymlink(url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
