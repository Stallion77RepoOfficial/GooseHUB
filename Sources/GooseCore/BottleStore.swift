import Darwin
import Foundation

enum PathGuard {
    static let manager = FileManager.default

    static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try manager.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    static func rejectSymlink(_ url: URL) throws {
        if try attributes(url)?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw HubError.unsafePath("symbolic link at \(url.path)")
        }
    }

    static func requireRegularFile(_ url: URL) throws {
        guard try attributes(url)?[.type] as? FileAttributeType == .typeRegular else {
            throw HubError.invalidMetadata("expected a regular file at \(url.path)")
        }
    }

    static func requireDirectory(_ url: URL) throws {
        guard try attributes(url)?[.type] as? FileAttributeType == .typeDirectory else {
            throw HubError.unsafePath("expected a directory at \(url.path)")
        }
    }

    /// Checks every component inside an owned directory. Wine's DOS device symlinks
    /// are never traversed by metadata or graphics deployment operations.
    static func contained(_ url: URL, in root: URL, allowLeafSymlink: Bool = false) throws {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else {
            throw HubError.unsafePath(url.path)
        }
        try rejectSymlink(root)
        var cursor = root
        for (index, component) in parts.dropFirst(rootParts.count).enumerated() {
            cursor.appendPathComponent(component)
            if allowLeafSymlink && index == parts.count - rootParts.count - 1 { continue }
            try rejectSymlink(cursor)
        }
    }

    static func makeDirectory(_ url: URL, inside root: URL) throws {
        try contained(url, in: root)
        try manager.createDirectory(at: url, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try requireDirectory(url)
    }

    static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HubError.invalidName
        }
        return trimmed
    }

    static func validateArguments(_ arguments: [String]) throws {
        guard arguments.count <= 1024,
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576,
              !arguments.contains(where: { $0.contains("\0") }) else { throw HubError.invalidArguments }
    }

    static func executable(_ url: URL, mustExist: Bool = true) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              ["exe", "msi"].contains(url.pathExtension.lowercased()) else {
            throw HubError.invalidExecutable(url.path)
        }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        if mustExist {
            guard try attributes(normalized)?[.type] as? FileAttributeType == .typeRegular else {
                throw HubError.invalidExecutable(normalized.path)
            }
        }
        return normalized
    }
}

struct BottleStore: Sendable {
    let root: URL
    var bottlesRoot: URL { root.appendingPathComponent("Bottles", isDirectory: true) }

    func runtimeSettings() throws -> RuntimeSettings {
        let file = root.appendingPathComponent("runtime-settings.json")
        try PathGuard.contained(file, in: root)
        guard try PathGuard.attributes(file) != nil else { return RuntimeSettings() }
        return try JSONFile.read(RuntimeSettings.self, at: file)
    }

    func saveRuntimeSettings(_ settings: RuntimeSettings) throws {
        try prepare()
        let file = root.appendingPathComponent("runtime-settings.json")
        try PathGuard.contained(file, in: root)
        try JSONFile.write(settings, to: file)
    }

    func directory(_ id: UUID) -> URL {
        bottlesRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func prefix(_ id: UUID) -> URL { directory(id).appendingPathComponent("prefix", isDirectory: true) }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try PathGuard.makeDirectory(bottlesRoot, inside: root)
    }

    func reserve(_ bottle: Bottle) throws {
        try prepare()
        let url = directory(bottle.id)
        guard try PathGuard.attributes(url) == nil else { throw HubError.unsafePath("bottle already exists") }
        try PathGuard.makeDirectory(url, inside: bottlesRoot)
        do {
            try JSONFile.write(OwnershipMarker(schemaVersion: 1, application: "GooseHUB", bottleID: bottle.id),
                               to: url.appendingPathComponent(".goose-owned.json"))
            try JSONFile.write(BottleDocument(bottle: bottle), to: url.appendingPathComponent("bottle.json"))
            try PathGuard.makeDirectory(url.appendingPathComponent("Logs"), inside: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func load(_ id: UUID) throws -> Bottle {
        let url = directory(id)
        guard try PathGuard.attributes(url) != nil else { throw HubError.bottleNotFound(id) }
        try PathGuard.contained(url, in: root)
        try PathGuard.requireDirectory(url)
        let marker = try JSONFile.read(OwnershipMarker.self, at: url.appendingPathComponent(".goose-owned.json"))
        guard marker.schemaVersion == 1, marker.application == "GooseHUB", marker.bottleID == id else {
            throw HubError.invalidMetadata("ownership marker mismatch at \(url.path)")
        }
        let document = try JSONFile.read(BottleDocument.self, at: url.appendingPathComponent("bottle.json"))
        guard document.schemaVersion == 1, document.bottle.id == id else {
            throw HubError.invalidMetadata("unsupported version or bottle ID mismatch at \(url.path)")
        }
        try validate(document.bottle)
        try PathGuard.contained(prefix(id), in: url)
        return document.bottle
    }

    func list() throws -> [Bottle] {
        guard try PathGuard.attributes(bottlesRoot) != nil else { return [] }
        try PathGuard.contained(bottlesRoot, in: root)
        try PathGuard.requireDirectory(bottlesRoot)
        return try FileManager.default.contentsOfDirectory(at: bottlesRoot,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]).map { url in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  url.lastPathComponent == id.uuidString.lowercased() else {
                throw HubError.invalidMetadata("unexpected entry in Bottles: \(url.lastPathComponent)")
            }
            return try load(id)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ bottle: Bottle) throws {
        _ = try load(bottle.id)
        try validate(bottle)
        try JSONFile.write(BottleDocument(bottle: bottle),
                           to: directory(bottle.id).appendingPathComponent("bottle.json"))
    }

    /// Clones a bottle's directory, prefix and all, under the copy's ID and without the original's
    /// logs. On APFS the clone shares the original's blocks until either side writes.
    func duplicate(_ id: UUID, as copy: Bottle) throws {
        _ = try load(id)
        let target = directory(copy.id)
        guard try PathGuard.attributes(target) == nil else { throw HubError.unsafePath("bottle already exists") }
        // Hidden until complete, so list() never meets a half-copied bottle.
        let partial = bottlesRoot.appendingPathComponent(".\(copy.id.uuidString.lowercased()).partial", isDirectory: true)
        try PathGuard.contained(partial, in: bottlesRoot)
        do {
            if clonefile(directory(id).path, partial.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                try FileManager.default.copyItem(at: directory(id), to: partial)
            }
            let logs = partial.appendingPathComponent("Logs", isDirectory: true)
            try FileManager.default.removeItem(at: logs)
            try PathGuard.makeDirectory(logs, inside: partial)
            try JSONFile.write(OwnershipMarker(schemaVersion: 1, application: "GooseHUB", bottleID: copy.id),
                               to: partial.appendingPathComponent(".goose-owned.json"))
            try JSONFile.write(BottleDocument(bottle: copy), to: partial.appendingPathComponent("bottle.json"))
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// The Trash keeps a deleted bottle until it is emptied, so a deletion can be undone.
    func trash(_ id: UUID) throws {
        _ = try load(id)
        try FileManager.default.trashItem(at: directory(id), resultingItemURL: nil)
    }

    func removeFailedCreation(_ id: UUID) throws {
        let bottle = try load(id)
        guard bottle.state == .creating else {
            throw HubError.invalidMetadata("refusing to remove an initialized bottle")
        }
        try FileManager.default.removeItem(at: directory(id))
    }

    func validate(_ bottle: Bottle) throws {
        _ = try PathGuard.validateName(bottle.name)
        guard bottle.updatedAt >= bottle.createdAt,
              bottle.applications.count <= 10_000,
              Set(bottle.applications.map(\.id)).count == bottle.applications.count,
              bottle.dxmt.maximumFrameRate.map({ (15...1000).contains($0) }) ?? true else {
            throw HubError.invalidMetadata("invalid dates, duplicate shortcuts, or graphics settings")
        }
        for application in bottle.applications {
            _ = try PathGuard.validateName(application.name)
            _ = try PathGuard.executable(URL(fileURLWithPath: application.executablePath), mustExist: false)
            guard application.executablePath.hasPrefix("/") else {
                throw HubError.invalidMetadata("shortcut path must be absolute")
            }
            try PathGuard.validateArguments(application.arguments)
        }
    }

    func writeLaunch(_ launch: LaunchRecord) throws {
        _ = try load(launch.bottleID)
        let logs = directory(launch.bottleID).appendingPathComponent("Logs", isDirectory: true)
        try PathGuard.makeDirectory(logs, inside: directory(launch.bottleID))
        try JSONFile.write(launch, to: logs.appendingPathComponent("\(launch.id.uuidString.lowercased()).json"))
    }

    func logURL(_ bottleID: UUID, id: UUID) throws -> URL {
        _ = try load(bottleID)
        let logs = directory(bottleID).appendingPathComponent("Logs", isDirectory: true)
        try PathGuard.makeDirectory(logs, inside: directory(bottleID))
        return logs.appendingPathComponent("\(id.uuidString.lowercased()).log")
    }
}
