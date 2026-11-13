import AppKit
import Darwin
import Foundation
import GooseCore

/// MetalGoose's settings (`CaptureSettings`) as its backend reports them, by stored raw value.
struct MetalGooseConfiguration: Equatable {
    var scalingMethod = "Off"
    var scaleFactor = "1.0x"
    var renderScale = "Native (100%)"
    var sharpening = "Ultra"
    var frameGenMode = "Off"
    var frameGenMultiplier = 2
    var aaMode = "Off"
    var alignPointer = true
    var showMGHUD = true
    var vsync = true
    var vrr = false
    var tripleBuffering = true

    var isUpscaling: Bool { scalingMethod != "Off" }

    init() {}

    init(_ value: [String: Any]) {
        let defaults = MetalGooseConfiguration()
        scalingMethod = value["scalingMethod"] as? String ?? defaults.scalingMethod
        scaleFactor = value["scaleFactor"] as? String ?? defaults.scaleFactor
        renderScale = value["renderScale"] as? String ?? defaults.renderScale
        sharpening = value["sharpening"] as? String ?? defaults.sharpening
        frameGenMode = value["frameGenMode"] as? String ?? defaults.frameGenMode
        frameGenMultiplier = (value["frameGenMultiplier"] as? NSNumber)?.intValue ?? defaults.frameGenMultiplier
        aaMode = value["aaMode"] as? String ?? defaults.aaMode
        alignPointer = value["alignPointer"] as? Bool ?? defaults.alignPointer
        showMGHUD = value["showMGHUD"] as? Bool ?? defaults.showMGHUD
        vsync = value["vsync"] as? Bool ?? defaults.vsync
        vrr = value["vrr"] as? Bool ?? defaults.vrr
        tripleBuffering = value["tripleBuffering"] as? Bool ?? defaults.tripleBuffering
    }

    var dictionary: [String: Any] {
        ["scalingMethod": scalingMethod, "scaleFactor": scaleFactor, "renderScale": renderScale,
         "sharpening": sharpening, "frameGenMode": frameGenMode, "frameGenMultiplier": frameGenMultiplier,
         "aaMode": aaMode, "alignPointer": alignPointer, "showMGHUD": showMGHUD, "vsync": vsync, "vrr": vrr,
         "tripleBuffering": tripleBuffering]
    }
}

/// Runs the MetalGoose backend, shows and changes its settings, and attaches it to the games Goose
/// HUB starts in a bottle that uses MetalGoose. Nobody picks a window: the game's process is found
/// among those its launch became, and MetalGoose takes that process's window as it takes the
/// frontmost app's. Settings stay MetalGoose's own, so a session started this way and one started
/// with ⌘⇧T run the same.
@MainActor
final class MetalGooseClient: ObservableObject {
    enum State: Equatable {
        case idle
        case waiting(String)
        case scaling(String)
        case stoppedByShortcut(String)
        case blocked(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var available: Bool
    @Published private(set) var configuration: MetalGooseConfiguration?
    @Published private(set) var screenRecordingGranted = true
    @Published private(set) var accessibilityGranted = true
    @Published private(set) var rates = ""
    @Published private(set) var sessionRunning = false
    /// What MetalGoose has to say, shown as its alert is in its app.
    @Published var alert: String?

    var permissionsGranted: Bool { screenRecordingGranted && accessibilityGranted }
    /// The bottle whose game MetalGoose follows, if any.
    var bottleID: UUID? { launch?.bottleID }

    private struct Launch {
        let id: UUID
        let bottleID: UUID
        let rootPID: pid_t
        let name: String
        var enabled = true
        var candidate: pid_t?
        var failures = 0
        var stoppedByShortcut = false
        var blocked = false
    }

    private var launch: Launch?
    private var startPending = false
    private var pendingConfigures: Set<String> = []
    private var timer: Timer?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorFile: FileHandle?
    private var buffer = Data()
    private var observers: [NSObjectProtocol] = []
    private var serviceID: UUID?
    private var pendingCommands: [String: String] = [:]

    init() {
        available = FileManager.default.isExecutableFile(atPath: Self.executable.path)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        })
        // Permissions are granted in System Settings, so coming back from there is when they change.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.process?.isRunning == true else { return }
                self.send("status")
            }
        })
    }

    private static var executable: URL {
        let root: URL
        if let value = ProcessInfo.processInfo.environment["GOOSE_ENGINES_ROOT"], !value.isEmpty {
            root = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
                .appendingPathComponent("Engines", isDirectory: true)
        }
        return root.appendingPathComponent("MetalGoose/bin/metalgoose-backend")
    }

    /// Starts the backend, which reports MetalGoose's settings, and builds the Neural Engine's models
    /// before a session needs them, as MetalGoose does when it launches.
    func prepare() {
        guard available, process == nil else { return }
        send("status")
    }

    func refresh() {
        guard available else { return }
        send("status")
    }

    // MARK: - Settings

    /// Shows the change at once; the backend's reply confirms what MetalGoose took.
    func configure(_ change: (inout MetalGooseConfiguration) -> Void) {
        var next = configuration ?? MetalGooseConfiguration()
        change(&next)
        configuration = next
        if let id = send("configure", fields: ["configuration": next.dictionary]) { pendingConfigures.insert(id) }
    }

    func requestScreenRecording() { send("request-permissions", fields: ["screenRecording": true]) }
    func requestAccessibility() { send("request-permissions", fields: ["accessibility": true]) }
    func clearMetalCache() { send("clear-metal-cache") }

    // MARK: - Following a launch

    /// MetalGoose attaches to the newest launch of a bottle that uses it.
    func follow(_ record: LaunchRecord) {
        guard available, record.processIdentifier > 0, launch?.id != record.id else { return }
        if sessionRunning { send("stop") }
        let name = URL(fileURLWithPath: record.executablePath).deletingPathExtension().lastPathComponent
        launch = Launch(id: record.id, bottleID: record.bottleID, rootPID: record.processIdentifier, name: name)
        state = .waiting(name)
        send("status")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// A bottle stopped or started using MetalGoose while its game runs.
    func setEnabled(_ enabled: Bool, bottleID: UUID) {
        guard var current = launch, current.bottleID == bottleID else { return }
        current.enabled = enabled
        launch = current
        if !enabled {
            if sessionRunning { send("stop") }
            state = .idle
        } else if !sessionRunning, !current.stoppedByShortcut, !current.blocked {
            state = .waiting(current.name)
        }
    }

    private func tick() {
        guard var current = launch else { return }
        if Darwin.kill(current.rootPID, 0) != 0, errno == ESRCH {
            // The launch has ended, and with it everything that was MetalGoose's to follow.
            launch = nil
            timer?.invalidate()
            timer = nil
            if sessionRunning { send("stop") }
            state = .idle
            rates = ""
            return
        }
        guard current.enabled, !current.stoppedByShortcut, !current.blocked, !startPending,
              !sessionRunning, permissionsGranted else { return }
        guard let window = GameWindow.find(in: ProcessTree.descendants(of: current.rootPID)) else {
            current.candidate = nil
            launch = current
            return
        }
        // Seen twice in a row: the game's window rather than a splash that closes at once.
        if current.candidate == window.pid {
            startPending = true
            send("start", fields: ["pid": window.pid])
        } else {
            current.candidate = window.pid
            launch = current
        }
    }

    // MARK: - Backend

    @discardableResult
    private func send(_ command: String, fields: [String: Any] = [:]) -> String? {
        let identifier = UUID().uuidString
        do {
            try ensureService()
            var request = fields
            request["id"] = identifier
            request["command"] = command
            var line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            line.append(0x0a)
            pendingCommands[identifier] = command
            try input?.fileHandleForWriting.write(contentsOf: line)
            return identifier
        } catch {
            pendingCommands.removeValue(forKey: identifier)
            if command == "start" { startPending = false }
            alert = error.localizedDescription
            return nil
        }
    }

    private func ensureService() throws {
        if let process, process.isRunning { return }
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? errorFile?.close()
        guard FileManager.default.isExecutableFile(atPath: Self.executable.path) else {
            throw NSError(domain: "GooseHUB", code: 1, userInfo: [NSLocalizedDescriptionKey: "The MetalGoose backend is missing from this build."])
        }
        let p = Process(); let stdinPipe = Pipe(); let stdoutPipe = Pipe()
        let identifier = UUID()
        p.executableURL = Self.executable; p.arguments = ["--serve"]
        p.standardInput = stdinPipe; p.standardOutput = stdoutPipe
        let logRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GooseHUB/Logs/MetalGoose")
        try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
        let log = logRoot.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        errorFile = try FileHandle(forWritingTo: log); try errorFile?.seekToEnd()
        p.standardError = errorFile
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in
                guard let self, self.serviceID == identifier else { return }
                self.consume(chunk)
            }
        }
        p.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.serviceID == identifier else { return }
                self.sessionRunning = false
                self.startPending = false
                self.pendingCommands.removeAll()
                self.pendingConfigures.removeAll()
                self.rates = ""
                if status != 0 { self.alert = "The MetalGoose backend exited with status \(status). See Logs/MetalGoose/backend.log." }
                if let current = self.launch, current.enabled, !current.stoppedByShortcut, !current.blocked {
                    self.state = .waiting(current.name)
                }
                self.output?.fileHandleForReading.readabilityHandler = nil
                try? self.input?.fileHandleForWriting.close()
                try? self.errorFile?.close()
                self.input = nil
                self.output = nil
                self.errorFile = nil
                self.process = nil
                self.serviceID = nil
            }
        }
        buffer = Data(); pendingCommands.removeAll(); input = stdinPipe; output = stdoutPipe; process = p; serviceID = identifier
        do { try p.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            try? stdinPipe.fileHandleForWriting.close()
            try? errorFile?.close()
            process = nil; input = nil; output = nil; errorFile = nil; serviceID = nil
            throw error
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard (value["protocolVersion"] as? NSNumber)?.intValue == 2 else {
                alert = "This MetalGoose backend speaks another protocol version."
                continue
            }
            let id = value["id"] as? String
            handle(value, command: id.flatMap { pendingCommands.removeValue(forKey: $0) }, id: id)
        }
        if buffer.count > 1_048_576 { buffer.removeAll(); alert = "The MetalGoose backend sent an unexpected reply." }
    }

    private func handle(_ value: [String: Any], command: String?, id: String?) {
        if command == "configure", let id { pendingConfigures.remove(id) }
        if let status = value["status"] as? [String: Any] { read(status) }
        if let message = value["message"] as? String { alert = message }
        if let failure = value["error"] as? [String: Any] {
            let code = failure["code"] as? String ?? ""
            let message = failure["message"] as? String ?? "MetalGoose failed."
            if code == "HUB-MG-PERMISSIONS" {
                send("status")
            } else if command == "start", var current = launch {
                // A process that lost its window between the look and the start is looked at again; a
                // start that keeps failing is reported and left alone.
                current.candidate = nil
                current.failures += 1
                if current.failures >= 3 {
                    current.blocked = true
                    state = .blocked("MetalGoose could not scale \(current.name): \(message)")
                }
                launch = current
            } else {
                alert = message
            }
        }
        if command == "start" {
            startPending = false
            if value["ok"] as? Bool == true, var current = launch {
                current.failures = 0
                launch = current
                state = .scaling(current.name)
            }
        }
        if command == "clear-metal-cache", value["ok"] as? Bool == true {
            // MetalGoose asks for a restart so shaders rebuild cleanly; the next use starts a fresh backend.
            send("quit")
        }
        switch (value["event"] as? String, value["reason"] as? String) {
        case ("stopped", "shortcut"?):
            if var current = launch { current.stoppedByShortcut = true; launch = current; state = .stoppedByShortcut(current.name) }
        case ("started", "shortcut"?):
            if var current = launch { current.stoppedByShortcut = false; launch = current; state = .scaling(current.name) }
        case ("stopped", "fullscreen"?):
            // MetalGoose's own message about it has just arrived as the alert.
            if var current = launch {
                current.blocked = true
                launch = current
                state = .blocked(alert ?? "\(current.name) entered macOS fullscreen, which MetalGoose cannot follow.")
                alert = nil
            }
        case ("stopped", _):
            if let current = launch, current.enabled, !current.blocked, !current.stoppedByShortcut { state = .waiting(current.name) }
            rates = ""
        default: break
        }
    }

    private func read(_ status: [String: Any]) {
        sessionRunning = (status["phase"] as? String ?? "idle") != "idle"
        screenRecordingGranted = status["screenRecordingGranted"] as? Bool ?? screenRecordingGranted
        accessibilityGranted = status["accessibilityGranted"] as? Bool ?? accessibilityGranted
        // A reply sent before a change arrived would undo it on screen.
        if pendingConfigures.isEmpty, let value = status["configuration"] as? [String: Any] {
            configuration = MetalGooseConfiguration(value)
        }
        if let metrics = status["metrics"] as? [String: Any] {
            let capture = (metrics["captureFPS"] as? NSNumber)?.doubleValue ?? 0
            let shown = (metrics["outputFPS"] as? NSNumber)?.doubleValue ?? 0
            let generated = (metrics["generatedFPS"] as? NSNumber)?.doubleValue ?? 0
            rates = String(format: "%.0f FPS captured, %.0f FPS shown, %.0f FPS generated", capture, shown, generated)
        } else {
            rates = ""
        }
    }
}

/// The processes a launch has become. Wine runs a game in the process Goose HUB started or in one
/// of its children, since a launcher can start the game itself.
enum ProcessTree {
    static func descendants(of root: pid_t) -> Set<pid_t> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [root] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [root] }
        var children: [pid_t: [pid_t]] = [:]
        for process in processes.prefix(size / stride) {
            children[process.kp_eproc.e_ppid, default: []].append(process.kp_proc.p_pid)
        }
        var found: Set<pid_t> = [root]
        var pending = [root]
        while let next = pending.popLast() {
            for child in children[next] ?? [] where found.insert(child).inserted { pending.append(child) }
        }
        return found
    }
}

/// The process showing a game's window: the one with the largest ordinary window among the launch's
/// processes, or with a window covering a display, where Wine raises a fullscreen game while it is in front.
struct GameWindow {
    let pid: pid_t

    /// Anything smaller is a launcher dialog or a helper.
    private static let minimumSize = CGSize(width: 320, height: 240)

    static func find(in processes: Set<pid_t>) -> GameWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let screens = displays.prefix(Int(count)).map(CGDisplayBounds)
        var best: (window: GameWindow, area: CGFloat)?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, processes.contains(owner),
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= minimumSize.width, height >= minimumSize.height else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 || screens.contains(where: { frame.contains($0) }) else { continue }
            if best.map({ width * height > $0.area }) ?? true { best = (GameWindow(pid: owner), width * height) }
        }
        return best?.window
    }
}
