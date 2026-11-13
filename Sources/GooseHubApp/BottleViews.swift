import AppKit
import SwiftUI
import GooseCore

struct BottleDetail: View {
    @EnvironmentObject private var model: HubModel
    let bottle: Bottle
    private var isRunning: Bool { model.running.contains { $0.bottleID == bottle.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Text("\(bottle.architecture.title) · \(bottle.windowsVersion.title)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
            }
            HStack(spacing: 10) {
                Button("Add Application…") { model.chooseApplication(in: bottle) }
                Button("Run Program…") { model.showRun = true }
                Button("Open C: Drive") { model.openDrive(bottle) }
                Menu("Wine Tools") {
                    ForEach(WineTool.allCases) { tool in
                        if tool == .reboot { Divider() }
                        Button(tool.title) { model.runTool(tool, in: bottle) }
                    }
                }.fixedSize()
                Spacer()
                Button("Stop Bottle") {
                    model.perform("Stopping \(bottle.name)…") { try await model.service.stop(bottleID: bottle.id) }
                }
                Menu { BottleMenu(bottle: bottle) } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden).fixedSize().help("Bottle")
            }.disabled(model.busy)
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Renderer").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Picker("Renderer", selection: Binding(get: { bottle.renderer }, set: { var changed = bottle; changed.renderer = $0; model.save(changed) })) {
                            Text("DXMT (Metal)").tag(Renderer.dxmt)
                            Text("WineD3D").tag(Renderer.wined3d)
                        }.labelsHidden().fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Synchronization").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Picker("Synchronization", selection: Binding(get: { bottle.synchronization }, set: { var changed = bottle; changed.synchronization = $0; model.save(changed) })) {
                            Text("MSync").tag(SynchronizationMode.msync)
                            Text("Default").tag(SynchronizationMode.none)
                        }.labelsHidden().fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Windows Version").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Picker("Windows Version", selection: Binding(get: { bottle.windowsVersion }, set: { var changed = bottle; changed.windowsVersion = $0; model.save(changed) })) {
                            ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    Spacer()
                }
                HStack(spacing: 24) {
                    Toggle("Metal Performance HUD", isOn: Binding(get: { bottle.dxmt.metalHUD }, set: { var changed = bottle; changed.dxmt.metalHUD = $0; model.save(changed) }))
                        .disabled(bottle.renderer != .dxmt)
                    Toggle("High Resolution Mode", isOn: Binding(get: { bottle.highResolution }, set: { var changed = bottle; changed.highResolution = $0; model.save(changed) }))
                        .help("Use the display’s full Retina resolution. This increases GPU load.")
                    Toggle("Verbose Wine Log", isOn: Binding(get: { bottle.debugLogging }, set: { var changed = bottle; changed.debugLogging = $0; model.save(changed) }))
                    Spacer()
                }.font(.system(size: 12))
                Divider().overlay(Theme.edge)
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Frame rate limit").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Picker("Frame rate limit", selection: Binding(get: { bottle.dxmt.maximumFrameRate ?? 0 }, set: {
                            var changed = bottle; changed.dxmt.maximumFrameRate = $0 == 0 ? nil : $0; model.save(changed)
                        })) {
                            ForEach(Array(Set([0, 30, 60, 90, 120, 144, 165, 240, bottle.dxmt.maximumFrameRate ?? 0])).sorted(), id: \.self) { rate in
                                Text(rate == 0 ? "Unlimited" : "\(rate) FPS").tag(rate)
                            }
                        }.labelsHidden().frame(width: 140)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shader compilation").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Picker("Shader compilation", selection: Binding(get: { bottle.dxmt.asyncPipelineCompilation }, set: {
                            var changed = bottle; changed.dxmt.asyncPipelineCompilation = $0; model.save(changed)
                        })) {
                            Text("Wait for shaders").tag(false)
                            Text("Background").tag(true)
                        }.labelsHidden().frame(width: 185)
                            .help("Waiting for shaders can pause rendering on a cold cache. Background compilation may skip draws until their shaders compile.")
                    }
                    Toggle("Shader cache", isOn: Binding(get: { bottle.dxmt.shaderCache }, set: {
                        var changed = bottle; changed.dxmt.shaderCache = $0; model.save(changed)
                    })).font(.system(size: 12))
                        .help("Reuse compiled shaders between launches to reduce compilation work.")
                    Spacer(minLength: 0)
                }.disabled(bottle.renderer != .dxmt)
                Text(isRunning ? "Stop the bottle to change these settings." : "Applies on the next launch.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.disabled(model.busy || isRunning).panel()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MetalGoose").font(.system(size: 15, weight: .semibold))
                    Text("Use the settings from the MetalGoose page.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("MetalGoose", isOn: Binding(get: { bottle.metalGoose.enabled }, set: { model.setMetalGoose($0, for: bottle) }))
                    .toggleStyle(.switch).labelsHidden().disabled(!model.metalGoose.available)
            }.panel()
            Text("Applications").font(.system(size: 17, weight: .semibold))
            let apps = bottle.applications.filter { model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search) }
            if apps.isEmpty {
                EmptyPanel(symbol: "app.badge", title: model.search.isEmpty ? "No applications" : "No matching applications",
                           message: model.search.isEmpty ? "Add a Windows program, or run an installer in this bottle." : "",
                           button: model.search.isEmpty ? "Add Application…" : "") { model.chooseApplication(in: bottle) }
            } else {
                LazyVStack(spacing: 9) { ForEach(apps) { app in ApplicationRow(application: app, bottle: bottle) } }
            }
        }
    }
}

struct ApplicationRow: View {
    @EnvironmentObject private var model: HubModel
    let application: SavedApplication
    let bottle: Bottle
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: application.executablePath.lowercased().hasSuffix(".msi") ? "shippingbox.fill" : "gamecontroller.fill")
                .font(.system(size: 20)).foregroundStyle(Theme.muted).frame(width: 46, height: 46)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(application.name).font(.system(size: 14, weight: .semibold))
                Text(bottle.name + "  ·  " + URL(fileURLWithPath: application.executablePath).lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Text(applicationRendererLabel(application, in: bottle)).font(.system(size: 10)).foregroundStyle(Theme.muted)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: application.executablePath)]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
            FavoriteButton(application: application, bottle: bottle)
            ApplicationPlayButton(application: application, bottle: bottle, showsTitle: true)
        }.padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.edge))
            .contextMenu { ApplicationMenu(application: application, bottle: bottle) }
    }
}

struct CreateBottleSheet: View {
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var architecture: BottleArchitecture = .arm64ec
    @State private var renderer: Renderer = .dxmt
    @State private var synchronization: SynchronizationMode = .msync
    @State private var windowsVersion: WindowsVersion = .win10
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Bottle").font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 11, weight: .medium))
                TextField("Games", text: $name).textFieldStyle(.roundedBorder)
            }
            Picker("Runtime", selection: $architecture) {
                Text("Native ARM64 · FEX").tag(BottleArchitecture.arm64ec)
                Text("x64 · Rosetta").tag(BottleArchitecture.x64).disabled(model.engineStatus?.wineX64Available != true)
            }
            Picker("Renderer", selection: $renderer) {
                Text("DXMT (Metal)").tag(Renderer.dxmt)
                Text("WineD3D").tag(Renderer.wined3d)
            }
            Picker("Synchronization", selection: $synchronization) {
                Text("MSync").tag(SynchronizationMode.msync)
                Text("Default").tag(SynchronizationMode.none)
            }
            Picker("Windows Version", selection: $windowsVersion) {
                ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
            }
            Text("Wine runs natively on ARM64; FEX translates x86 and x64 programs.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            if model.engineStatus?.wineAvailable != true { Text("This build has no Wine engine. The Engines page shows what is missing.").font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), architecture: architecture, renderer: renderer,
                                 synchronization: synchronization, windowsVersion: windowsVersion)
                    dismiss()
                }.buttonStyle(AccentButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.engineStatus?.wineAvailable != true).keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 460).background(Theme.background)
    }
}

struct RunCommandSheet: View {
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    @State private var executable: URL?
    @State private var arguments = ""
    @State private var addShortcut = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Run Program in \(bottle.name)").font(.system(size: 22, weight: .bold))
            HStack {
                Text(executable?.path ?? "Choose an .exe or .msi file.").font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Choose…") { Task { executable = await HubModel.chooseExecutable() } }
            }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Text("Arguments").font(.system(size: 12, weight: .medium))
                Text("Example: -game cstrike. Use double quotes for paths with spaces.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                TextEditor(text: $arguments).font(.system(size: 11, design: .monospaced)).frame(height: 80).padding(6).background(Theme.panel)
            }
            Toggle("Add to Library", isOn: $addShortcut).font(.system(size: 12))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Run") {
                    guard let url = executable else { return }
                    model.run(url, arguments: LaunchArguments.parse(arguments), addShortcut: addShortcut, in: bottle)
                    dismiss()
                }.buttonStyle(AccentButtonStyle()).disabled(executable == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 520).background(Theme.background)
    }
}

/// What a bottle's own menu offers, in its detail and in the sidebar.
struct BottleMenu: View {
    @EnvironmentObject private var model: HubModel
    let bottle: Bottle
    var body: some View {
        Button("Rename…") { model.renaming = bottle }
        Button("Duplicate…") { model.duplicating = bottle }
        Button("Open C: Drive") { model.openDrive(bottle) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.deleting = bottle }
    }
}

/// One name, for renaming or duplicating a bottle.
struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let action: String
    @State var name: String
    let commit: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 22, weight: .bold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { commit(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 420).background(Theme.background)
    }
}

struct EditApplicationSheet: View {
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    let edit: ApplicationEdit
    @State private var name: String
    @State private var arguments: String

    init(edit: ApplicationEdit) {
        self.edit = edit
        _name = State(initialValue: edit.application.name)
        _arguments = State(initialValue: LaunchArguments.format(edit.application.arguments))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit \(edit.application.name)").font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 11, weight: .medium))
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            }
            Text(edit.application.executablePath).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 7) {
                Text("Arguments").font(.system(size: 12, weight: .medium))
                Text("Example: -game cstrike. Use double quotes for paths with spaces.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                TextEditor(text: $arguments).font(.system(size: 11, design: .monospaced)).frame(height: 80).padding(6).background(Theme.panel)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.update(edit, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 arguments: LaunchArguments.parse(arguments))
                    dismiss()
                }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(30).frame(width: 520).background(Theme.background)
    }
}

extension View {
    func panel() -> some View { padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.edge)) }
}
