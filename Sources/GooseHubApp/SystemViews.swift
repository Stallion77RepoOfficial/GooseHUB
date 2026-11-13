import AppKit
import SwiftUI
import GooseCore

struct EnginesView: View {
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var setup: EngineSetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            EngineInstallationView(setup: setup)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("64-bit x87 math", isOn: Binding(
                    get: { model.runtimeSettings.reducedX87Precision },
                    set: { model.setReducedX87Precision($0) }))
                    .help("Faster x87 emulation. Installers use full precision. Restart games after changing this setting.")
                Toggle("Legacy OpenGL batching", isOn: Binding(
                    get: { model.runtimeSettings.legacyOpenGLBatching },
                    set: { model.setLegacyOpenGLBatching($0) }))
                    .help("Groups OpenGL calls in 32-bit games. Restart games after changing this setting.")
            }.font(.system(size: 12)).disabled(model.busy).panel()
            HStack {
                Spacer()
                Button("Show Engine Files") {
                    if let path = model.engineStatus?.rootPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }.buttonStyle(.borderless)
            }.font(.system(size: 11))
        }
    }
}

struct SessionsView: View {
    @EnvironmentObject private var model: HubModel
    @State private var filter = "all"
    @State private var selectedLog: LaunchRecord?
    private var visibleRecords: [LaunchRecord] {
        model.records.filter { record in
            filter == "all" || (filter == "running" && record.status == .running)
                || (filter == "issues" && (record.status == .failed || record.status == .interrupted
                    || (record.exitCode != nil && record.exitCode != 0)))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Sessions", selection: $filter) {
                    Text("All").tag("all")
                    Text("Running").tag("running")
                    Text("Errors").tag("issues")
                }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
            }
            if visibleRecords.isEmpty {
                EmptyPanel(symbol: "list.bullet.rectangle", title: "No sessions", message: "", button: "") {}
            }
            ForEach(visibleRecords.prefix(200)) { record in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: record.executablePath).lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text("\(model.bottles.first { $0.id == record.bottleID }?.name ?? "") · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(record.status.rawValue.capitalized).font(.system(size: 11)).foregroundStyle(record.status == .running ? Theme.success : Theme.muted)
                        Text(record.exitCode.map { "Exit \($0)" } ?? "PID \(record.processIdentifier)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                    Button("View Log") { selectedLog = record }.font(.system(size: 11))
                    if record.status == .running {
                        Button { model.perform("Stopping…") { try await model.service.stop(bottleID: record.bottleID) } } label: { Image(systemName: "stop.fill") }
                            .disabled(model.busy).help("Stop Bottle")
                    }
                }.panel()
            }
        }.sheet(item: $selectedLog) { SessionLogView(record: $0) }
    }
}

private struct SessionLogView: View {
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    let record: LaunchRecord
    @State private var output = "Loading…"
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(URL(fileURLWithPath: record.executablePath).lastPathComponent).font(.system(size: 19, weight: .semibold))
                    Text("Last 256 KB").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Refresh") { Task { await reload() } }.disabled(loading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
            }.background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        }.padding(24).frame(width: 800, height: 540).background(Theme.panel)
            .task { await reload() }
    }
    private func reload() async {
        loading = true
        defer { loading = false }
        do { output = try await model.service.readLaunchLog(bottleID: record.bottleID, launchID: record.id) }
        catch { output = error.localizedDescription }
    }
}
