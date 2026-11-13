import Foundation
import GooseCore
import SwiftUI

enum EngineComponent: String, CaseIterable, Identifiable {
    case wine, fex, dxmt, metalgoose
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wine: return "Wine Adrenalin Edition"
        case .fex: return "FEX Adrenalin Edition"
        case .dxmt: return "DXMT Adrenalin Edition"
        case .metalgoose: return "MetalGoose"
        }
    }
}

struct ComponentInstallation {
    var installed = false
    var percent = 0.0
    var running = false
    var queued = false
    var failure: String?
    var lastCheck: String?
}

@MainActor
final class EngineSetupModel: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var components = Dictionary(uniqueKeysWithValues: EngineComponent.allCases.map { ($0, ComponentInstallation()) })
    @Published private(set) var log = ""
    private var process: Process?
    private var queue: [EngineComponent] = []
    private var lineBuffer = Data()

    func state(_ component: EngineComponent) -> ComponentInstallation { components[component] ?? ComponentInstallation() }
    var active: Bool { components.values.contains { $0.running || $0.queued } }

    func check() async {
        let status = await HubService().diagnose()
        let availability: [EngineComponent: Bool] = [.wine: status.wineAvailable && status.vulkanAvailable,
            .fex: status.fexAvailable, .dxmt: status.dxmtAvailable, .metalgoose: status.metalGooseAvailable]
        for component in EngineComponent.allCases where !state(component).running && !state(component).queued {
            components[component]?.installed = availability[component] == true
            if state(component).installed { components[component]?.percent = 100 }
        }
        installed = status.isUsable
    }

    func canInstall(_ component: EngineComponent) -> Bool {
        if component != .dxmt { return true }
        let wine = state(.wine)
        return wine.installed || wine.running || wine.queued
    }

    func start(_ component: EngineComponent) {
        guard !state(component).running, !state(component).queued, canInstall(component) else { return }
        components[component]?.failure = nil
        components[component]?.lastCheck = nil
        components[component]?.percent = 0
        components[component]?.queued = true
        queue.append(component)
        next()
    }

    func cancel(_ component: EngineComponent) {
        if state(component).running { process?.terminate() }
        else {
            queue.removeAll { $0 == component }
            components[component]?.queued = false
        }
    }

    private func next() {
        guard process == nil, !queue.isEmpty else { return }
        let component = queue.removeFirst()
        components[component]?.queued = false
        guard let script = Bundle.main.url(forResource: "install-engines", withExtension: "py", subdirectory: "Bootstrap") else {
            components[component]?.failure = "Installer missing. Rebuild GooseHUB."
            next()
            return
        }
        let task = Process()
        let pipe = Pipe()
        let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/usr/bin/python3"
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [script.path, "--app", Bundle.main.bundleURL.path, "--component", component.rawValue]
        if state(component).installed { task.arguments?.append("--update") }
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        task.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1"
        ]) { _, value in value }
        lineBuffer.removeAll()
        log = ""
        components[component]?.running = true
        if !state(component).installed { installed = false }
        do {
            process = task
            try task.run()
            Task.detached(priority: .utility) { [weak self] in
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    await self?.append(data, component: component)
                }
                try? handle.close()
                task.waitUntilExit()
                await self?.finished(component, code: task.terminationStatus)
            }
        }
        catch {
            process = nil
            components[component]?.running = false
            components[component]?.failure = error.localizedDescription
            next()
        }
    }

    private func finished(_ component: EngineComponent, code: Int32) async {
        process = nil
        components[component]?.running = false
        if code != 0 && state(component).failure == nil {
            components[component]?.failure = "Installation stopped. See build log."
        }
        await check()
        next()
    }

    private func append(_ data: Data, component: EngineComponent) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let line = String(decoding: lineBuffer[..<newline], as: UTF8.self)
            lineBuffer.removeSubrange(...newline)
            if line.hasPrefix("@goose "), let eventData = String(line.dropFirst(7)).data(using: .utf8),
               let event = try? JSONDecoder().decode(InstallEvent.self, from: eventData),
               event.component == component.rawValue {
                components[component]?.percent = event.percent
                if event.phase == "failed" { components[component]?.failure = event.message }
                if event.phase == "up-to-date" {
                    components[component]?.lastCheck = event.message
                    log += event.message + "\n"
                } else if event.phase == "complete" {
                    components[component]?.lastCheck = "Updated."
                }
            } else {
                log += line + "\n"
                if log.count > 24000 { log = String(log.suffix(18000)) }
            }
        }
    }

    private struct InstallEvent: Decodable {
        let component: String
        let phase: String
        let message: String
        let percent: Double
    }
}

struct EngineSetupView: View {
    @ObservedObject var setup: EngineSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 14) {
                BrandMark(size: 48)
                Text("Goose HUB").font(.system(size: 25, weight: .semibold))
                Spacer()
                AppUpdateMenu()
            }
            EngineInstallationView(setup: setup)
        }
        .padding(48).frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
    }
}

struct EngineInstallationView: View {
    @ObservedObject var setup: EngineSetupModel
    @EnvironmentObject private var updater: AutoUpdater
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(EngineComponent.allCases) { component in
                let state = setup.state(component)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        Image(systemName: state.installed ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(state.installed ? Theme.success : Theme.muted)
                            .accessibilityLabel(state.installed ? "Installed" : "Not installed")
                        Text(component.title).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(Int(state.percent))%")
                            .monospacedDigit().font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .frame(width: 42, alignment: .trailing)
                        if state.running || state.queued {
                            Button("Cancel") { setup.cancel(component) }.frame(width: 140)
                        } else {
                            Button(state.failure != nil ? "Retry" : state.installed ? "Check for updates" : "Install") { setup.start(component) }
                                .disabled(!setup.canInstall(component) || !updater.canCheck).frame(width: 140)
                                .help(setup.canInstall(component) ? state.lastCheck ?? component.title : "Install Wine first")
                        }
                    }
                    ProgressView(value: state.percent, total: 100).controlSize(.small)
                    if let failure = state.failure {
                        Text(failure).font(.system(size: 11)).foregroundStyle(Theme.accent).textSelection(.enabled)
                    }
                }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            }
            if !setup.log.isEmpty {
                DisclosureGroup("Build log", isExpanded: $showLog) {
                    ScrollView {
                        Text(setup.log).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: 140).padding(10).background(Theme.panel)
                }.font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }
}
