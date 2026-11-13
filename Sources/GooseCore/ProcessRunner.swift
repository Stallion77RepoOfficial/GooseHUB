import Darwin
import Foundation

/// Process owns the child PID. This wrapper never adopts a persisted PID, which
/// prevents a restart from terminating an unrelated process after PID reuse.
final class ManagedProcess: @unchecked Sendable {
    let process: Process
    let output: FileHandle
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    init(invocation: ProcessInvocation, logURL: URL) throws {
        try PathGuard.rejectSymlink(logURL)
        guard try PathGuard.attributes(logURL) == nil else {
            throw HubError.unsafePath("launch log already exists: \(logURL.path)")
        }
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HubError.processFailed("could not create log at \(logURL.path)")
        }
        output = try FileHandle(forWritingTo: logURL)
        process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        var header: [String: Any] = ["executable": invocation.executable.path, "arguments": invocation.arguments,
                                     "prefix": invocation.environment["WINEPREFIX"] ?? "",
                                     "workingDirectory": invocation.workingDirectory.path]
        if let reduced = invocation.environment["FEX_X87REDUCEDPRECISION"] {
            header["x87MathBits"] = reduced == "1" ? 64 : 80
        }
        if invocation.environment["WINE_GL_BATCHING"] == "1" { header["legacyOpenGLBatching"] = true }
        let data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        try output.write(contentsOf: data + Data("\n".utf8))
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let running = process.isRunning
        let pid = process.processIdentifier
        if running { process.terminate() }
        lock.unlock()
        guard running, pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            // The Process object remains attached to this child until it exits.
            if process.isRunning && process.processIdentifier == pid { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? output.synchronize()
        try? output.close()
    }

    deinit { close() }
}

enum ProcessRunner {
    static func execute(_ invocation: ProcessInvocation, logURL: URL, timeoutSeconds: Int = 120) async throws -> Int32 {
        let runner = try ManagedProcess(invocation: invocation, logURL: logURL)
        defer { runner.close() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try runner.start()
                    runner.process.waitUntilExit()
                    return runner.process.terminationStatus
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    runner.terminate()
                    throw HubError.processTimedOut(invocation.executable.lastPathComponent)
                }
                do {
                    guard let status = try await group.next() else { throw CancellationError() }
                    group.cancelAll()
                    return status
                } catch {
                    runner.terminate()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            runner.terminate()
        }
    }
}
