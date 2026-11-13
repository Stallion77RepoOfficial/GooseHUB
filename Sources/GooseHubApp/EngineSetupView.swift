import AppKit
import Foundation
import GooseCore
import SwiftUI

@MainActor
final class EngineSetupModel: ObservableObject {
    @Published var installed = false
    @Published var running = false
    @Published var phase = ""
    @Published var message = ""
    @Published var log = ""
    @Published var failure: String?
    @Published var sourceFolder: String
    private var process: Process?
    private var pendingLine = ""

    init() {
        sourceFolder = UserDefaults.standard.string(forKey: "engineSourceFolder")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Github").path
    }

    func check() async {
        installed = await HubService().diagnose().isUsable
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: sourceFolder)
        panel.prompt = "Use Source Folder"
        if panel.runModal() == .OK, let url = panel.url { sourceFolder = url.path }
    }

    func start() {
        guard !running else { return }
        guard let script = Bundle.main.url(forResource: "install-engines", withExtension: "py", subdirectory: "Bootstrap") else {
            failure = "The engine installer is missing. Rebuild or download the GooseHUB app."
            return
        }
        let task = Process()
        let pipe = Pipe()
        let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/usr/bin/python3"
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [script.path, "--app", Bundle.main.bundleURL.path, "--sources-root", sourceFolder]
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        task.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1"
        ]) { _, value in value }
        log = ""; pendingLine = ""; failure = nil; phase = "tools"; message = "Checking build tools"
        running = true
        UserDefaults.standard.set(sourceFolder, forKey: "engineSourceFolder")
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.append(text) }
        }
        task.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.running = false
                self.process = nil
                await self.check()
                if code != 0 && self.failure == nil {
                    self.failure = "Installation stopped. The build log below contains the failed step. You can retry."
                } else if code == 0 && !self.installed {
                    self.failure = "The engine installation is incomplete. Review the build log and retry."
                }
            }
        }
        do { process = task; try task.run() }
        catch { running = false; process = nil; failure = error.localizedDescription }
    }

    func cancel() { process?.terminate() }

    private func append(_ text: String) {
        log += text
        if log.count > 24000 { log = String(log.suffix(18000)) }
        pendingLine += text
        while let newline = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[..<newline])
            pendingLine.removeSubrange(...newline)
            guard line.hasPrefix("@goose "), let data = String(line.dropFirst(7)).data(using: .utf8),
                  let event = try? JSONDecoder().decode(InstallEvent.self, from: data) else { continue }
            phase = event.phase
            message = event.message
            if event.phase == "failed" { failure = event.message }
        }
    }

    private struct InstallEvent: Decodable { let phase: String; let message: String }
}

struct EngineSetupView: View {
    @ObservedObject var setup: EngineSetupModel
    @State private var showLog = false
    private let phases = ["tools", "sources", "wine", "fex", "dxmt", "install", "metalgoose", "verify", "complete"]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                BrandMark(size: 48)
                Text("Goose HUB").font(.system(size: 25, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Install the engines").font(.system(size: 30, weight: .medium))
                Text("GooseHUB downloads the Wine, FEX and DXMT Adrenalin sources from GitHub and builds them on this Mac. The library opens when installation is complete.")
                    .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Text("Xcode with the Metal toolchain and Homebrew are required. Build tools and media dependencies are installed during setup. Private repositories use your existing Git credentials.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Source folder").font(.system(size: 12, weight: .medium))
                HStack {
                    Text(setup.sourceFolder).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { setup.chooseFolder() }.disabled(setup.running)
                }.padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 13) {
                component("Wine Adrenalin Edition", phase: "wine")
                component("FEX Adrenalin Edition", phase: "fex")
                component("DXMT Adrenalin Edition", phase: "dxmt")
            }
            if setup.running {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(setup.message).font(.system(size: 13))
                    Spacer()
                    Button("Cancel") { setup.cancel() }
                }
            } else {
                Button(setup.failure == nil ? "Download and Build" : "Retry Installation") { setup.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if let failure = setup.failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(Theme.accent).textSelection(.enabled)
            }
            if !setup.log.isEmpty {
                DisclosureGroup("Build log", isExpanded: $showLog) {
                    ScrollView {
                        Text(setup.log).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: 160).padding(10).background(Theme.panel)
                }.font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(48).frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
    }

    private func component(_ name: String, phase: String) -> some View {
        let current = phases.firstIndex(of: setup.phase) ?? -1
        let index = phases.firstIndex(of: phase) ?? 0
        return HStack {
            Text(name).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(current > index ? "Built" : current == index ? "Building…" : "Pending")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }.padding(.vertical, 4)
    }
}
