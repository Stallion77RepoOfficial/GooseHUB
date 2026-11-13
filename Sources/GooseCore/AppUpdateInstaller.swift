import Foundation
import Security
import Darwin

public enum AppUpdateInstaller {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func replace(archive: URL, currentApp: URL, bundleIdentifier: String, lockURL: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let lockPath = lockURL ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/GooseHUB/engine-install.lock")
        try fm.createDirectory(at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockPath.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw Failure(message: "Cannot open the update lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure(message: "A component update is running. Wait for it to finish.")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let staging = currentApp.deletingLastPathComponent().appendingPathComponent(".goosehub-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        func app(in directory: URL) -> URL? {
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
                .first { $0.pathExtension == "app" }
        }
        let folders = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        guard let candidate = app(in: staging) ?? folders.lazy.compactMap({ app(in: $0) }).first else {
            throw Failure(message: "No .app bundle found in the update.")
        }
        try validate(candidate, bundleIdentifier: bundleIdentifier)
        let enginePath = "Contents/Resources/Engines"
        guard !fm.fileExists(atPath: candidate.appendingPathComponent(enginePath).path) else {
            throw Failure(message: "The launcher update must not bundle engines.")
        }
        let engines = currentApp.appendingPathComponent(enginePath)
        if fm.fileExists(atPath: engines.path) {
            let destination = candidate.appendingPathComponent(enginePath)
            do { try run("/bin/cp", ["-cRp", engines.path, destination.path]) }
            catch {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: engines, to: destination)
            }
            let entitlements = candidate.appendingPathComponent("Contents/Resources/Bootstrap/GooseHUB.entitlements")
            guard fm.fileExists(atPath: entitlements.path) else {
                throw Failure(message: "The update is missing GooseHUB entitlements.")
            }
            try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, candidate.path])
            try validate(candidate, bundleIdentifier: bundleIdentifier)
        }
        let backupName = ".goosehub-previous-\(UUID().uuidString).app"
        let backup = currentApp.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            _ = try fm.replaceItemAt(currentApp, withItemAt: candidate, backupItemName: backupName,
                                     options: [.withoutDeletingBackupItem])
            try validate(currentApp, bundleIdentifier: bundleIdentifier)
        } catch {
            if fm.fileExists(atPath: backup.path) {
                if fm.fileExists(atPath: currentApp.path) {
                    try fm.moveItem(at: currentApp, to: staging.appendingPathComponent("failed.app"))
                }
                try fm.moveItem(at: backup, to: currentApp)
            }
            throw error
        }
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        return currentApp
    }

    private static func validate(_ app: URL, bundleIdentifier: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure(message: "The update does not contain a valid GooseHUB app.")
        }
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw Failure(message: "The update's code signature is invalid.")
        }
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(String(decoding: data.suffix(2000), as: UTF8.self))")
        }
    }
}
