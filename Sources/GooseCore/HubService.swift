import Foundation

/// Owns Goose HUB's prefixes and children. It never opens or upgrades a bottle
/// belonging to CrossOver, another Wine wrapper, or another prefix directory.
public actor HubService {
    private let store: BottleStore
    private let engines: EngineLayout
    private let inheritedEnvironment: [String: String]
    private var records: [UUID: LaunchRecord] = [:]
    private var processes: [UUID: ManagedProcess] = [:]

    public init(dataRoot: URL? = nil, enginesRoot: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let selectedRoot = dataRoot ?? environment["GOOSE_DATA_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GooseHUB")
        store = BottleStore(root: selectedRoot.standardizedFileURL.resolvingSymlinksInPath())
        engines = EngineLayout(root: enginesRoot, environment: environment)
        inheritedEnvironment = environment
    }

    public func diagnose() -> EngineStatus { engines.status() }

    private func requireInstalledEngines() throws {
        guard engines.status().isUsable else {
            throw HubError.engineUnavailable("Complete the Wine, FEX and DXMT installation in GooseHUB first.")
        }
    }

    public func runtimeSettings() throws -> RuntimeSettings { try store.runtimeSettings() }

    public func updateRuntimeSettings(_ settings: RuntimeSettings) throws {
        try store.saveRuntimeSettings(settings)
    }

    public func listBottles() throws -> [Bottle] { try store.list() }

    public func bottleDirectory(_ id: UUID) throws -> URL {
        _ = try store.load(id)
        return store.directory(id)
    }

    public func prefixDirectory(_ id: UUID) throws -> URL {
        _ = try store.load(id)
        return store.prefix(id)
    }

    public func createBottle(name: String, architecture: BottleArchitecture = .arm64ec,
                             renderer: Renderer = .dxmt, synchronization: SynchronizationMode = .msync,
                             windowsVersion: WindowsVersion = .win10) async throws -> Bottle {
        let name = try PathGuard.validateName(name)
        try requireInstalledEngines()
        try engines.requireWine(architecture)
        if renderer == .dxmt { _ = try DXMTDeployment.plan(architecture: architecture, engines: engines) }
        var bottle = Bottle(name: name, architecture: architecture, renderer: renderer,
                            synchronization: synchronization, windowsVersion: windowsVersion, state: .creating)
        try store.reserve(bottle)
        let logID = UUID()
        let initializationLog = try store.logURL(bottle.id, id: logID)
        let prefix = store.prefix(bottle.id)
        let invocation = ProcessInvocation(executable: engines.wine(architecture), arguments: ["wineboot", "-u"],
            environment: RuntimeEnvironment.build(bottle: bottle, prefix: prefix, engines: engines,
                                                  inherited: inheritedEnvironment, initialize: true),
            workingDirectory: store.directory(bottle.id))
        do {
            let status = try await ProcessRunner.execute(invocation, logURL: initializationLog)
            guard status == 0 else { throw HubError.prefixInitializationFailed(status, initializationLog.path) }
            try PathGuard.contained(prefix.appendingPathComponent("drive_c/windows/system32"), in: store.directory(bottle.id))
            try PathGuard.requireDirectory(prefix.appendingPathComponent("drive_c/windows/system32"))
            if renderer == .dxmt {
                try DXMTDeployment.install(bottle: bottle, directory: store.directory(bottle.id),
                                           prefix: prefix, engines: engines)
            }
            // A new prefix reports Windows 10.
            if windowsVersion != .win10 { try await configure(bottle, ["winecfg", "-v", windowsVersion.rawValue]) }
            bottle.state = .ready
            bottle.updatedAt = Date()
            try store.save(bottle)
            return try store.load(bottle.id)
        } catch {
            // Wine can have started a server before wineboot failed. Stop only
            // this newly reserved prefix before removing its failed creation.
            await cleanFailedPrefix(bottle)
            let failureLog = preserveCreationLog(initializationLog, bottleID: bottle.id)
            try? store.removeFailedCreation(bottle.id)
            if case HubError.prefixInitializationFailed(let code, _) = error {
                throw HubError.prefixInitializationFailed(code, failureLog?.path ?? initializationLog.path)
            }
            throw error
        }
    }

    public func updateBottle(_ bottle: Bottle) async throws {
        let previous = try store.load(bottle.id)
        guard !hasRunningProcesses(bottle.id) else { throw HubError.bottleBusy(bottle.id) }
        guard previous.architecture == bottle.architecture else { throw HubError.architectureCannotChange }
        guard previous.createdAt == bottle.createdAt, previous.state == .ready, bottle.state == .ready else {
            throw HubError.invalidMetadata("creation date and lifecycle cannot be changed")
        }
        var updated = bottle
        updated.name = try PathGuard.validateName(updated.name)
        // MetalGoose's settings change through updateMetalGoose, which a stale copy must not undo.
        updated.metalGoose = previous.metalGoose
        updated.updatedAt = Date()
        try store.validate(updated)
        if updated.renderer == .dxmt {
            try DXMTDeployment.install(bottle: updated, directory: store.directory(updated.id),
                                       prefix: store.prefix(updated.id), engines: engines)
        } else if previous.renderer == .dxmt {
            try DXMTDeployment.restore(bottle: previous, directory: store.directory(updated.id),
                                       prefix: store.prefix(updated.id))
        }
        // Both live in the prefix's registry, which only Wine's own tools write safely.
        if updated.windowsVersion != previous.windowsVersion {
            try await configure(updated, ["winecfg", "-v", updated.windowsVersion.rawValue])
        }
        if updated.highResolution != previous.highResolution {
            try await configure(updated, ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode",
                                          "/t", "REG_SZ", "/d", updated.highResolution ? "y" : "n", "/f"])
        }
        try store.save(updated)
    }

    /// Names can change while the bottle's programs run: the prefix never sees them.
    @discardableResult
    public func renameBottle(bottleID: UUID, name: String) throws -> Bottle {
        var bottle = try store.load(bottleID)
        bottle.name = try PathGuard.validateName(name)
        bottle.updatedAt = Date()
        try store.save(bottle)
        return try store.load(bottleID)
    }

    /// A copy of a stopped bottle, prefix and all, under a new name. Shortcuts into the original
    /// prefix point into the copy's.
    public func duplicateBottle(bottleID: UUID, name: String) async throws -> Bottle {
        let source = try store.load(bottleID)
        guard source.state == .ready else { throw HubError.invalidMetadata("bottle initialization is incomplete") }
        guard !hasRunningProcesses(bottleID) else { throw HubError.bottleBusy(bottleID) }
        // A wineserver left by a tool or a crashed game can still be writing the registry.
        try await stop(bottleID: bottleID)
        var copy = Bottle(name: try PathGuard.validateName(name), architecture: source.architecture,
                          renderer: source.renderer, synchronization: source.synchronization,
                          applications: [], dxmt: source.dxmt, metalGoose: source.metalGoose,
                          debugLogging: source.debugLogging, windowsVersion: source.windowsVersion,
                          highResolution: source.highResolution)
        let sourcePrefix = store.prefix(bottleID).path + "/"
        let copyPrefix = store.prefix(copy.id).path + "/"
        copy.applications = source.applications.map { application in
            var moved = SavedApplication(name: application.name, executablePath: application.executablePath,
                                         arguments: application.arguments, isFavorite: application.isFavorite)
            if application.executablePath.hasPrefix(sourcePrefix) {
                moved.executablePath = copyPrefix + application.executablePath.dropFirst(sourcePrefix.count)
            }
            return moved
        }
        try store.duplicate(bottleID, as: copy)
        return try store.load(copy.id)
    }

    /// Stops the bottle's programs, then moves the bottle to the Trash.
    public func deleteBottle(bottleID: UUID) async throws {
        let bottle = try store.load(bottleID)
        if bottle.state == .ready, (try? engines.requireWine(bottle.architecture)) != nil {
            try await stop(bottleID: bottleID)
        }
        for (launchID, record) in records where record.bottleID == bottleID {
            processes.removeValue(forKey: launchID)?.close()
            records.removeValue(forKey: launchID)
        }
        try store.trash(bottleID)
    }

    /// MetalGoose's settings leave the prefix alone, so they change while the bottle's games run.
    @discardableResult
    public func updateMetalGoose(bottleID: UUID, settings: MetalGooseSettings) throws -> Bottle {
        var bottle = try store.load(bottleID)
        bottle.metalGoose = settings
        bottle.updatedAt = Date()
        try store.validate(bottle)
        try store.save(bottle)
        return try store.load(bottleID)
    }

    @discardableResult
    public func addApplication(bottleID: UUID, name: String, executable: URL,
                                arguments: [String] = []) throws -> Bottle {
        var bottle = try store.load(bottleID)
        guard bottle.state == .ready else { throw HubError.invalidMetadata("bottle initialization is incomplete") }
        let name = try PathGuard.validateName(name)
        let executable = try PathGuard.executable(executable)
        try PathGuard.validateArguments(arguments)
        bottle.applications.append(SavedApplication(name: name, executablePath: executable.path, arguments: arguments))
        bottle.updatedAt = Date()
        try store.save(bottle)
        return try store.load(bottleID)
    }

    @discardableResult
    public func removeApplication(bottleID: UUID, applicationID: UUID) throws -> Bottle {
        var bottle = try store.load(bottleID)
        guard bottle.applications.contains(where: { $0.id == applicationID }) else {
            throw HubError.applicationNotFound(applicationID)
        }
        bottle.applications.removeAll { $0.id == applicationID }
        bottle.updatedAt = Date()
        try store.save(bottle)
        return try store.load(bottleID)
    }

    @discardableResult
    public func updateApplication(bottleID: UUID, applicationID: UUID, name: String,
                                  arguments: [String]) throws -> Bottle {
        var bottle = try store.load(bottleID)
        guard let index = bottle.applications.firstIndex(where: { $0.id == applicationID }) else {
            throw HubError.applicationNotFound(applicationID)
        }
        bottle.applications[index].name = try PathGuard.validateName(name)
        try PathGuard.validateArguments(arguments)
        bottle.applications[index].arguments = arguments
        bottle.updatedAt = Date()
        try store.save(bottle)
        return try store.load(bottleID)
    }

    public func runApplication(bottleID: UUID, applicationID: UUID) async throws -> LaunchRecord {
        let bottle = try store.load(bottleID)
        guard let application = bottle.applications.first(where: { $0.id == applicationID }) else {
            throw HubError.applicationNotFound(applicationID)
        }
        return try await run(bottleID: bottleID, executable: URL(fileURLWithPath: application.executablePath),
                             arguments: application.arguments)
    }

    @discardableResult
    public func setApplicationFavorite(bottleID: UUID, applicationID: UUID, isFavorite: Bool) throws -> Bottle {
        var bottle = try store.load(bottleID)
        guard let index = bottle.applications.firstIndex(where: { $0.id == applicationID }) else {
            throw HubError.applicationNotFound(applicationID)
        }
        bottle.applications[index].isFavorite = isFavorite
        bottle.updatedAt = Date()
        try store.save(bottle)
        return try store.load(bottleID)
    }

    public func run(bottleID: UUID, executable: URL, arguments: [String] = []) async throws -> LaunchRecord {
        try requireInstalledEngines()
        let bottle = try store.load(bottleID)
        guard bottle.state == .ready else { throw HubError.invalidMetadata("bottle initialization is incomplete") }
        try engines.requireWine(bottle.architecture)
        let executable = try PathGuard.executable(executable)
        try PathGuard.validateArguments(arguments)
        let prefix = store.prefix(bottleID)
        try PathGuard.requireDirectory(prefix)
        if bottle.renderer == .dxmt {
            // Never mutate graphics DLLs while another process in this prefix is
            // running. All settings remain fixed for a launched session.
            if !hasRunningProcesses(bottleID) {
                try DXMTDeployment.install(bottle: bottle, directory: store.directory(bottleID),
                                           prefix: prefix, engines: engines)
            }
        }
        if !hasRunningProcesses(bottleID) { try await installMonoIfMissing(bottle) }
        let invocation = ProcessInvocation.application(bottle: bottle, prefix: prefix, executable: executable,
            arguments: arguments, engines: engines, inherited: inheritedEnvironment,
            settings: try store.runtimeSettings())
        return try start(invocation, bottleID: bottleID, executablePath: executable.path, arguments: arguments)
    }

    /// Runs one of Wine's programs in the bottle. It shows up in the sessions like an application.
    public func runTool(bottleID: UUID, tool: WineTool) async throws -> LaunchRecord {
        let bottle = try store.load(bottleID)
        guard bottle.state == .ready else { throw HubError.invalidMetadata("bottle initialization is incomplete") }
        try engines.requireWine(bottle.architecture)
        let prefix = store.prefix(bottleID)
        try PathGuard.requireDirectory(prefix)
        if bottle.renderer == .dxmt && !hasRunningProcesses(bottleID) {
            try DXMTDeployment.install(bottle: bottle, directory: store.directory(bottleID),
                                       prefix: prefix, engines: engines)
        }
        let invocation = ProcessInvocation(executable: engines.wine(bottle.architecture), arguments: tool.command,
            environment: RuntimeEnvironment.build(bottle: bottle, prefix: prefix, engines: engines,
                                                  inherited: inheritedEnvironment),
            workingDirectory: store.directory(bottleID))
        return try start(invocation, bottleID: bottleID, executablePath: tool.command[0] + ".exe",
                         arguments: Array(tool.command.dropFirst()))
    }

    private func start(_ invocation: ProcessInvocation, bottleID: UUID, executablePath: String,
                       arguments: [String]) throws -> LaunchRecord {
        let id = UUID()
        let log = try store.logURL(bottleID, id: id)
        let runner = try ManagedProcess(invocation: invocation, logURL: log)
        var record = LaunchRecord(id: id, bottleID: bottleID, executablePath: executablePath, arguments: arguments,
            startedAt: Date(), endedAt: nil, processIdentifier: 0, status: .running, exitCode: nil, logPath: log.path)
        runner.process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { await self?.finished(id, exitCode: code) }
        }
        do {
            try runner.start()
            record.processIdentifier = runner.process.processIdentifier
            try store.writeLaunch(record)
        } catch {
            runner.terminate()
            runner.close()
            record.status = .failed
            record.endedAt = Date()
            records[id] = record
            try? store.writeLaunch(record)
            throw HubError.processFailed(error.localizedDescription)
        }
        records[id] = record
        processes[id] = runner
        return record
    }

    public func launches(bottleID: UUID? = nil) -> [LaunchRecord] {
        records.values.filter { bottleID == nil || $0.bottleID == bottleID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func launchHistory(bottleID: UUID) throws -> [LaunchRecord] {
        _ = try store.load(bottleID)
        let logs = store.directory(bottleID).appendingPathComponent("Logs", isDirectory: true)
        try PathGuard.contained(logs, in: store.directory(bottleID))
        guard try PathGuard.attributes(logs) != nil else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }.map { url in
            var record = try JSONFile.read(LaunchRecord.self, at: url)
            guard record.bottleID == bottleID,
                  url.deletingPathExtension().lastPathComponent == record.id.uuidString.lowercased(),
                  URL(fileURLWithPath: record.logPath).standardizedFileURL == logs.appendingPathComponent("\(record.id.uuidString.lowercased()).log") else {
                throw HubError.invalidMetadata("launch record mismatch at \(url.path)")
            }
            if let current = records[record.id] { return current }
            if record.status == .running { record.status = .interrupted }
            return record
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// A bounded tail keeps large Wine logs from exhausting the UI.
    public func readLaunchLog(bottleID: UUID, launchID: UUID, maximumBytes: Int = 262_144) throws -> String {
        let url = try store.logURL(bottleID, id: launchID)
        try PathGuard.requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let limit = UInt64(min(max(maximumBytes, 4096), 1_048_576))
        let start = length > limit ? length - limit : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(limit)) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0 {
            if let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            text = "[Showing the end of this log]\n" + text
        }
        return text.isEmpty ? "No output yet." : text
    }

    public func waitForLaunch(_ launchID: UUID) async throws -> LaunchRecord {
        while let record = records[launchID] {
            if record.status != .running { return record }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HubError.processFailed("unknown launch ID")
    }

    public func stop(bottleID: UUID) async throws {
        let bottle = try store.load(bottleID)
        try engines.requireWine(bottle.architecture)
        guard bottle.state == .ready else { throw HubError.invalidMetadata("bottle initialization is incomplete") }
        let id = UUID()
        let log = try store.logURL(bottleID, id: id)
        let invocation = ProcessInvocation(executable: engines.wineserver(bottle.architecture), arguments: ["-k"],
            environment: RuntimeEnvironment.build(bottle: bottle, prefix: store.prefix(bottleID), engines: engines,
                                                  inherited: inheritedEnvironment),
            workingDirectory: store.directory(bottleID))
        let status = try await ProcessRunner.execute(invocation, logURL: log, timeoutSeconds: 15)
        // 1 is wineserver's answer when no server was running: the bottle was already stopped.
        guard status == 0 || status == 1 else { throw HubError.processFailed("wineserver -k returned \(status); log: \(log.path)") }
        for (launchID, process) in processes where records[launchID]?.bottleID == bottleID { process.terminate() }
    }

    /// Wine installs Wine Mono, its .NET runtime, into every prefix it creates. Bottles made before the
    /// engines carried the package get it once, before their next program starts.
    private func installMonoIfMissing(_ bottle: Bottle) async throws {
        let directory = engines.wineRoot(bottle.architecture).appendingPathComponent("share/wine/mono")
        guard let package = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .first(where: { $0.hasPrefix("wine-mono-") && $0.hasSuffix(".msi") }),
              try PathGuard.attributes(store.prefix(bottle.id).appendingPathComponent("drive_c/windows/mono")) == nil
        else { return }
        // msiexec takes a Windows path; every prefix maps Z: to the Mac's root.
        let path = "Z:" + directory.appendingPathComponent(package).path.replacingOccurrences(of: "/", with: "\\")
        try await configure(bottle, ["msiexec", "/i", path, "/qn"])
    }

    /// Runs a Wine command to completion in a stopped bottle, for the settings that live in its prefix.
    private func configure(_ bottle: Bottle, _ command: [String]) async throws {
        try engines.requireWine(bottle.architecture)
        let log = try store.logURL(bottle.id, id: UUID())
        let invocation = ProcessInvocation(executable: engines.wine(bottle.architecture), arguments: command,
            environment: RuntimeEnvironment.build(bottle: bottle, prefix: store.prefix(bottle.id), engines: engines,
                                                  inherited: inheritedEnvironment),
            workingDirectory: store.directory(bottle.id))
        let status = try await ProcessRunner.execute(invocation, logURL: log, timeoutSeconds: 300)
        guard status == 0 else { throw HubError.processFailed("\(command.joined(separator: " ")) returned \(status); log: \(log.path)") }
    }

    private func hasRunningProcesses(_ bottleID: UUID) -> Bool {
        records.values.contains { $0.bottleID == bottleID && $0.status == .running }
    }

    private func finished(_ id: UUID, exitCode: Int32) {
        guard var record = records[id] else { return }
        record.exitCode = exitCode
        record.endedAt = Date()
        record.status = exitCode == 0 ? .exited : .failed
        processes.removeValue(forKey: id)?.close()
        records[id] = record
        do { try store.writeLaunch(record) }
        catch {
            // The child has exited even if storage is no longer writable. Keep
            // its state in memory and append the persistence failure.
            if let handle = FileHandle(forWritingAtPath: record.logPath) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\nGoose HUB could not save launch status: \(error.localizedDescription)\n".utf8))
                try? handle.close()
            }
        }
    }

    private func cleanFailedPrefix(_ bottle: Bottle) async {
        guard let log = try? store.logURL(bottle.id, id: UUID()) else { return }
        let invocation = ProcessInvocation(executable: engines.wineserver(bottle.architecture), arguments: ["-k"],
            environment: RuntimeEnvironment.build(bottle: bottle, prefix: store.prefix(bottle.id), engines: engines,
                                                  inherited: inheritedEnvironment, initialize: true),
            workingDirectory: store.directory(bottle.id))
        _ = try? await Task.detached {
            try await ProcessRunner.execute(invocation, logURL: log, timeoutSeconds: 10)
        }.value
    }

    private func preserveCreationLog(_ log: URL, bottleID: UUID) -> URL? {
        do {
            let failures = store.root.appendingPathComponent("FailedCreations", isDirectory: true)
            try PathGuard.makeDirectory(failures, inside: store.root)
            let target = failures.appendingPathComponent("\(bottleID.uuidString.lowercased()).log")
            try PathGuard.requireRegularFile(log)
            try FileManager.default.copyItem(at: log, to: target)
            return target
        } catch { return nil }
    }
}
