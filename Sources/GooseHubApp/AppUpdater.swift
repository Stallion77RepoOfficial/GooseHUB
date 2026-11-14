// Update flow adapted from MetalGoose (GPL-3.0).
import AppKit
import GooseCore
import CryptoKit
import Foundation
import Security

struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String
    /// `sha256:<hex>`, computed by GitHub when the asset was uploaded. Absent on releases that predate it.
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

enum UpdateState {
    case idle
    case checking
    case upToDate
    case available(release: GitHubRelease)
    case downloading(progress: Double)
    case installing
    case done
    case failed(String)

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }


}

private enum UpdateError: LocalizedError {
    case http(Int)
    case noAsset
    case untrustedSource
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .http(let code):        return String(localized: "GitHub answered with status \(code).")
        case .noAsset:               return String(localized: "No downloadable .zip asset found in release.")
        case .untrustedSource:       return String(localized: "Release asset is not served from GitHub over HTTPS; refusing to install it.")
        case .checksumMismatch:      return String(localized: "The downloaded update does not match the checksum GitHub published for it; refusing to install it.")
        }
    }
}

@MainActor
final class AutoUpdater: ObservableObject {

    static let shared = AutoUpdater()

    private let repository = "Stallion77RepoOfficial/GooseHUB"

    @Published var state: UpdateState = .idle

    private init() {}

    var canCheck: Bool { if case .idle = state { return true }; return false }

    func checkForUpdates() {
        guard case .idle = state else { return }
        state = .checking
        Task { await check() }
    }

    func downloadAndInstall(release: GitHubRelease) {
        guard case .available = state else { return }
        state = .downloading(progress: 0)
        Task { await install(release) }
    }

    // MARK: - Checking

    private func check() async {
        do {
            let release = try await fetchLatestRelease()
            let latest = SemanticVersion(release.tagName)
            let current = SemanticVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            state = latest > current ? .available(release: release) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GooseHUB-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - Installing

    private func install(_ release: GitHubRelease) async {
        do {
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let url = URL(string: asset.browserDownloadURL) else { throw UpdateError.noAsset }

            // The installer replaces the running bundle. Accept only GitHub HTTPS
            // assets and verify the published checksum when available.
            guard Self.isGitHubHTTPS(url) else { throw UpdateError.untrustedSource }

            let archive = try await download(url)
            defer { try? FileManager.default.removeItem(at: archive) }

            if let expected = asset.digest?.lowercased().replacingOccurrences(of: "sha256:", with: ""),
               try await Self.sha256(of: archive) != expected {
                throw UpdateError.checksumMismatch
            }

            state = .installing
            let installed = try await Task.detached { try Self.extractAndReplace(archive) }.value
            Self.removeQuarantine(at: installed)
            state = .done
            Self.relaunch(installed)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func isGitHubHTTPS(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    private func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        request.setValue("GooseHUB-Updater", forHTTPHeaderField: "User-Agent")

        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(progress: fraction)
            }
        }
        let (file, response) = try await URLSession.shared.download(for: request, delegate: progress)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError.http(http.statusCode)
        }
        return file
    }

    /// Reports the real byte count from the transfer instead of guessing it from the size of the file
    /// on disk.
    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            report(min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    private static func sha256(of file: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private nonisolated static func extractAndReplace(_ archive: URL) throws -> URL {
        try AppUpdateInstaller.replace(archive: archive, currentApp: Bundle.main.bundleURL,
                                       bundleIdentifier: "dev.goosehub.adrenalin")
    }

    private nonisolated static func removeQuarantine(at url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// Waits for this process to exit, then opens the new bundle.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quotedPath = app.path.replacingOccurrences(of: "'", with: "'\\''")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open -n '\(quotedPath)'"]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try? shell.run()
        // The completed progress sheet must allow the updater's termination request.
        for window in NSApplication.shared.windows {
            window.attachedSheet?.preventsApplicationTerminationWhenModal = false
        }
        NSApplication.shared.terminate(nil)
    }
}
