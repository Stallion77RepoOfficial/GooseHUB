import CryptoKit
import Foundation

struct DLLDeploymentEntry: Codable, Equatable, Sendable {
    let destination: String
    let originalBackup: String?
    let originalFingerprint: String?
    let installedFingerprint: String
}

struct DLLDeploymentState: Codable, Equatable {
    let schemaVersion: Int
    let architecture: BottleArchitecture
    let entries: [DLLDeploymentEntry]
}

struct DLLCopy: Sendable {
    let source: URL
    let destination: String
}

enum DXMTDeployment {
    static let libraries = ["d3d8.dll", "d3d9.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "winemetal.dll"]
    static let requiredLibraries = ["d3d11.dll", "dxgi.dll", "winemetal.dll"]

    static func plan(architecture: BottleArchitecture, engines: EngineLayout) throws -> [DLLCopy] {
        guard engines.dxmtReady(architecture) else {
            throw HubError.engineUnavailable("DXMT payload or the native winemetal bridge is incomplete for \(architecture.rawValue).")
        }
        let mappings = [(architecture == .arm64ec ? "arm64ec" : "x64", "system32"), ("x86", "syswow64")]
        return try mappings.flatMap { sourceArch, destinationArch in
            try libraries.compactMap { library -> DLLCopy? in
                let source = engines.dxmtDirectory(sourceArch).appendingPathComponent(library)
                guard try PathGuard.attributes(source) != nil else { return nil }
                try PathGuard.requireRegularFile(source)
                return DLLCopy(source: source, destination: "drive_c/windows/\(destinationArch)/\(library)")
            }
        }
    }

    static func fingerprint(_ url: URL) throws -> String {
        let attributes = try PathGuard.attributes(url)
        let data: Data
        switch attributes?[.type] as? FileAttributeType {
        case .typeRegular:
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        case .typeSymbolicLink:
            data = Data(("symlink:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))).utf8)
        default: throw HubError.deploymentFailed("expected a DLL file at \(url.path)")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ state: DLLDeploymentState, bottle: Bottle, directory: URL, prefix: URL) throws {
        guard state.schemaVersion == 1, state.architecture == bottle.architecture,
              Set(state.entries.map(\.destination)).count == state.entries.count else {
            throw HubError.deploymentFailed("invalid deployment record")
        }
        let allowed = Set(["system32", "syswow64"].flatMap { architecture in
            libraries.map { "drive_c/windows/\(architecture)/\($0)" }
        })
        for entry in state.entries {
            guard allowed.contains(entry.destination) else {
                throw HubError.deploymentFailed("invalid DLL destination in deployment record")
            }
            try PathGuard.contained(prefix.appendingPathComponent(entry.destination), in: prefix, allowLeafSymlink: true)
            if let backup = entry.originalBackup {
                guard backup == "Backups/DXMT/original/\(entry.destination)", let original = entry.originalFingerprint else {
                    throw HubError.deploymentFailed("invalid original DLL backup record")
                }
                let backupURL = directory.appendingPathComponent(backup)
                try PathGuard.contained(backupURL, in: directory, allowLeafSymlink: true)
                guard try fingerprint(backupURL) == original else {
                    throw HubError.deploymentFailed("original DLL backup changed: \(backup)")
                }
            } else if entry.originalFingerprint != nil {
                throw HubError.deploymentFailed("inconsistent original DLL backup record")
            }
        }
    }

    /// Keeps an original-file backup and a transaction journal before replacing
    /// any system DLL. A failed operation restores every destination it touched.
    static func install(bottle: Bottle, directory: URL, prefix: URL, engines: EngineLayout) throws {
        let fm = FileManager.default
        let manifest = directory.appendingPathComponent(".goose-dxmt.json")
        let pending = directory.appendingPathComponent(".goose-dxmt.pending.json")
        try PathGuard.contained(prefix, in: directory)
        try PathGuard.requireDirectory(prefix)
        if try PathGuard.attributes(pending) != nil {
            // A journal left by an interrupted host must never authorize another
            // overwrite. The original DLL backups remain available for recovery.
            throw HubError.deploymentFailed("an interrupted DXMT transaction needs recovery at \(pending.path)")
        }
        let existing: DLLDeploymentState? = try PathGuard.attributes(manifest) == nil
            ? nil : JSONFile.read(DLLDeploymentState.self, at: manifest)
        if let existing { try validate(existing, bottle: bottle, directory: directory, prefix: prefix) }
        let copies = try plan(architecture: bottle.architecture, engines: engines)
        let oldEntries = Dictionary(uniqueKeysWithValues: (existing?.entries ?? []).map { ($0.destination, $0) })
        var entries: [DLLDeploymentEntry] = []
        var changes: [DLLCopy] = []
        for copy in copies {
            let destination = prefix.appendingPathComponent(copy.destination)
            try PathGuard.contained(destination, in: prefix, allowLeafSymlink: true)
            try PathGuard.requireDirectory(destination.deletingLastPathComponent())
            let installed = try fingerprint(copy.source)
            if let prior = oldEntries[copy.destination] {
                let current = try fingerprint(destination)
                guard current == prior.installedFingerprint || current == installed else {
                    throw HubError.deploymentFailed("DLL changed outside Goose HUB; refusing to overwrite \(copy.destination)")
                }
                entries.append(DLLDeploymentEntry(destination: copy.destination, originalBackup: prior.originalBackup,
                    originalFingerprint: prior.originalFingerprint, installedFingerprint: installed))
                if current != installed { changes.append(copy) }
            } else {
                let present = try PathGuard.attributes(destination) != nil
                let backup = present ? "Backups/DXMT/original/\(copy.destination)" : nil
                if let backup, try PathGuard.attributes(directory.appendingPathComponent(backup)) != nil {
                    throw HubError.deploymentFailed("untracked DLL backup exists at \(backup)")
                }
                entries.append(DLLDeploymentEntry(destination: copy.destination, originalBackup: backup,
                    originalFingerprint: present ? try fingerprint(destination) : nil, installedFingerprint: installed))
                changes.append(copy)
            }
        }
        let plannedDestinations = Set(entries.map(\.destination))
        for previous in existing?.entries ?? [] where !plannedDestinations.contains(previous.destination) {
            guard try fingerprint(prefix.appendingPathComponent(previous.destination)) == previous.installedFingerprint else {
                throw HubError.deploymentFailed("previously deployed DLL changed: \(previous.destination)")
            }
            entries.append(previous)
        }
        let state = DLLDeploymentState(schemaVersion: 1, architecture: bottle.architecture, entries: entries)
        guard !changes.isEmpty else {
            if existing != state { try JSONFile.write(state, to: manifest) }
            return
        }
        let staging = directory.appendingPathComponent(".dxmt-staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        try PathGuard.makeDirectory(staging, inside: directory)
        var preserveStaging = false
        defer { if !preserveStaging { try? fm.removeItem(at: staging) } }
        // Copy and hash every source before touching the prefix.
        for change in changes {
            let staged = staging.appendingPathComponent("new/\(change.destination)")
            try PathGuard.makeDirectory(staged.deletingLastPathComponent(), inside: staging)
            try fm.copyItem(at: change.source, to: staged)
            guard try fingerprint(staged) == fingerprint(change.source) else {
                throw HubError.deploymentFailed("staged source changed while copying")
            }
        }
        try JSONFile.write(state, to: pending)
        var touched: [(destination: URL, rollback: URL, hadOriginal: Bool)] = []
        var newBackups: [URL] = []
        do {
            for change in changes {
                let destination = prefix.appendingPathComponent(change.destination)
                let rollback = staging.appendingPathComponent("previous/\(change.destination)")
                let hadOriginal = try PathGuard.attributes(destination) != nil
                if oldEntries[change.destination] == nil,
                   let entry = entries.first(where: { $0.destination == change.destination }),
                   let backupPath = entry.originalBackup {
                    let backup = directory.appendingPathComponent(backupPath)
                    try PathGuard.makeDirectory(backup.deletingLastPathComponent(), inside: directory)
                    try fm.copyItem(at: destination, to: backup)
                    newBackups.append(backup)
                    guard try fingerprint(backup) == entry.originalFingerprint else {
                        throw HubError.deploymentFailed("original backup verification failed")
                    }
                }
                try PathGuard.makeDirectory(rollback.deletingLastPathComponent(), inside: staging)
                if hadOriginal { try fm.moveItem(at: destination, to: rollback) }
                touched.append((destination, rollback, hadOriginal))
                try fm.moveItem(at: staging.appendingPathComponent("new/\(change.destination)"), to: destination)
            }
            try JSONFile.write(state, to: manifest)
            try? fm.removeItem(at: pending)
        } catch {
            var rollbackFailed = false
            for item in touched.reversed() {
                do {
                    if try PathGuard.attributes(item.destination) != nil { try fm.removeItem(at: item.destination) }
                    if item.hadOriginal { try fm.moveItem(at: item.rollback, to: item.destination) }
                } catch { rollbackFailed = true }
            }
            if !rollbackFailed {
                for backup in newBackups { try? fm.removeItem(at: backup) }
                try? fm.removeItem(at: pending)
            }
            if rollbackFailed {
                preserveStaging = true
                throw HubError.deploymentFailed("transaction recovery required; backups and journal retained at \(directory.path)")
            }
            throw error
        }
    }

    static func restore(bottle: Bottle, directory: URL, prefix: URL) throws {
        let fm = FileManager.default
        let manifest = directory.appendingPathComponent(".goose-dxmt.json")
        let pending = directory.appendingPathComponent(".goose-dxmt.pending.json")
        guard try PathGuard.attributes(manifest) != nil else { return }
        guard try PathGuard.attributes(pending) == nil else {
            throw HubError.deploymentFailed("an interrupted graphics transaction needs recovery")
        }
        let state = try JSONFile.read(DLLDeploymentState.self, at: manifest)
        try validate(state, bottle: bottle, directory: directory, prefix: prefix)
        for entry in state.entries {
            guard try fingerprint(prefix.appendingPathComponent(entry.destination)) == entry.installedFingerprint else {
                throw HubError.deploymentFailed("DLL changed outside Goose HUB; refusing to restore \(entry.destination)")
            }
        }
        let staging = directory.appendingPathComponent(".dxmt-restore-\(UUID().uuidString.lowercased())", isDirectory: true)
        try PathGuard.makeDirectory(staging, inside: directory)
        var preserveStaging = false
        defer { if !preserveStaging { try? fm.removeItem(at: staging) } }
        for entry in state.entries {
            if let original = entry.originalBackup {
                let target = staging.appendingPathComponent("original/\(entry.destination)")
                try PathGuard.makeDirectory(target.deletingLastPathComponent(), inside: staging)
                try fm.copyItem(at: directory.appendingPathComponent(original), to: target)
            }
        }
        try JSONFile.write(state, to: pending)
        var touched: [(destination: URL, rollback: URL)] = []
        do {
            for entry in state.entries {
                let destination = prefix.appendingPathComponent(entry.destination)
                let rollback = staging.appendingPathComponent("deployed/\(entry.destination)")
                try PathGuard.makeDirectory(rollback.deletingLastPathComponent(), inside: staging)
                try fm.moveItem(at: destination, to: rollback)
                touched.append((destination, rollback))
                if entry.originalBackup != nil {
                    try fm.moveItem(at: staging.appendingPathComponent("original/\(entry.destination)"), to: destination)
                }
            }
            try fm.removeItem(at: manifest)
        } catch {
            var rollbackFailed = false
            for item in touched.reversed() {
                do {
                    if try PathGuard.attributes(item.destination) != nil { try fm.removeItem(at: item.destination) }
                    try fm.moveItem(at: item.rollback, to: item.destination)
                } catch { rollbackFailed = true }
            }
            if !rollbackFailed { try? fm.removeItem(at: pending) }
            else { preserveStaging = true }
            throw HubError.deploymentFailed(rollbackFailed
                ? "graphics recovery required; originals retained at \(directory.path)"
                : error.localizedDescription)
        }
        for entry in state.entries {
            if let backup = entry.originalBackup { try? fm.removeItem(at: directory.appendingPathComponent(backup)) }
        }
        try? fm.removeItem(at: pending)
    }
}
