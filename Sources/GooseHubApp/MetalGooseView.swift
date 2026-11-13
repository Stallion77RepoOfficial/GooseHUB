import AppKit
import Combine
import SwiftUI
import GooseCore

/// MetalGoose's choices, by the raw value it stores and the title it shows (`Options.swift`).
enum MetalGooseOptions {
    static let scalingMethods = [("Off", "Off"), ("MGUP-1", "MGUP-1")]
    static let scaleFactors = ["1.0x", "1.5x", "2.0x", "2.5x", "3.0x", "4.0x", "5.0x", "6.0x", "8.0x", "10.0x"].map { ($0, $0) }
        + [("Fullscreen", "Fullscreen")]
    static let renderScales = ["Native (100%)", "75%", "67%", "50%", "33%"].map { ($0, $0) }
    static let sharpening = [("Performance", "Light"), ("Balanced", "Balanced"), ("Ultra", "Strong")]
    static let frameGenModes = [("Off", "Off"), ("MGFG-1", "MGFG-1")]
    static let antiAliasing = [("Off", "Off"), ("FXAA", "FXAA"), ("SMAA", "SMAA")]

    /// The multipliers a frame generation mode can deliver, lowest first (`FrameGenMode.multipliers`).
    static func multipliers(_ mode: String) -> [Int] { mode == "MGFG-1" ? [2, 4] : [1] }
}

/// MetalGoose's window, in Goose HUB: its permission banner and its settings, laid out as its
/// `ContentView` lays them out. The Start Scaling button is not here; MetalGoose attaches to the
/// games of the bottles that use it, and ⌘⇧T works as in MetalGoose.
struct MetalGooseView: View {
    @ObservedObject var client: MetalGooseClient
    private let monitor = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !client.available {
                Text("MetalGoose is missing.").font(.system(size: 12)).foregroundStyle(.orange)
            } else {
                if !client.permissionsGranted {
                    PermissionBanner(client: client).padding(.bottom, 8)
                }
                status
                if let configuration = client.configuration {
                    HStack(alignment: .top, spacing: 20) {
                        leftColumn(configuration)
                        rightColumn(configuration)
                    }
                    .disabled(!client.permissionsGranted)
                    .opacity(client.permissionsGranted ? 1.0 : 0.5)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("⌘⇧T  Toggle scaling     ⌘⇧C  Toggle pointer")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .onAppear { client.prepare() }
        // Permissions are granted in another app, which does not tell this one (`PermissionManager`).
        .onReceive(monitor) { _ in if !client.permissionsGranted { client.refresh() } }
    }

    @ViewBuilder private var status: some View {
        switch client.state {
        case .idle:
            EmptyView()
        case .waiting(let name):
            Text("Waiting for \(name)…").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .scaling(let name):
            VStack(alignment: .leading, spacing: 4) {
                Text("Scaling \(name)").font(.system(size: 12, weight: .medium))
                if !client.rates.isEmpty { Text(client.rates).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted) }
            }
        case .stoppedByShortcut(let name):
            Text("Scaling paused for \(name). Press ⌘⇧T to resume.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        case .blocked(let reason):
            Text(reason).font(.system(size: 12)).foregroundStyle(.orange)
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<MetalGooseConfiguration, Value>) -> Binding<Value> {
        Binding(get: { (client.configuration ?? MetalGooseConfiguration())[keyPath: path] },
                set: { value in client.configure { $0[keyPath: path] = value } })
    }

    private func leftColumn(_ configuration: MetalGooseConfiguration) -> some View {
        VStack(spacing: 16) {
            ConfigPanel(title: "Upscaling") {
                PickerRow(label: "Method", selection: binding(\.scalingMethod), options: MetalGooseOptions.scalingMethods)
                if configuration.isUpscaling {
                    PickerRow(label: "Scale Factor", selection: binding(\.scaleFactor), options: MetalGooseOptions.scaleFactors)
                    PickerRow(label: "Render Scale", selection: binding(\.renderScale), options: MetalGooseOptions.renderScales)
                }
            }

            ConfigPanel(title: "Frame Generation") {
                PickerRow(label: "Mode", selection: binding(\.frameGenMode), options: MetalGooseOptions.frameGenModes)

                // A mode with one multiplier has nothing to choose, and a row that reports a figure
                // nothing can change reads as a control that stopped responding.
                if configuration.frameGenMode != "Off" {
                    SliderRow(label: "Multiplier", value: binding(\.frameGenMultiplier),
                              values: MetalGooseOptions.multipliers(configuration.frameGenMode))
                }
            }

            ConfigPanel(title: "Anti-Aliasing") {
                PickerRow(label: "Mode", selection: binding(\.aaMode), options: MetalGooseOptions.antiAliasing)
            }
        }
    }

    private func rightColumn(_ configuration: MetalGooseConfiguration) -> some View {
        VStack(spacing: 16) {
            if configuration.isUpscaling {
                ConfigPanel(title: "MGUP-1 Settings") {
                    PickerRow(label: "Sharpening", selection: binding(\.sharpening), options: MetalGooseOptions.sharpening)
                }
            }

            ConfigPanel(title: "Display Settings") {
                ToggleRow(label: "Show MG HUD", isOn: binding(\.showMGHUD))
                ToggleRow(label: "Align Pointer", isOn: binding(\.alignPointer))
                ToggleRow(label: "VSync", isOn: binding(\.vsync))
                ToggleRow(label: "VRR", isOn: binding(\.vrr))
                ToggleRow(label: "Triple Buffering", isOn: binding(\.tripleBuffering))
                    .disabled(client.sessionRunning)
            }

            VStack {
                Button {
                    client.clearMetalCache()
                } label: {
                    Text("Clear Metal Cache").frame(maxWidth: .infinity)
                }
                .disabled(client.sessionRunning)
            }
        }
    }
}

/// What is missing before scaling can start, and the way to get it (MetalGoose's `PermissionBanner`).
struct PermissionBanner: View {
    @ObservedObject var client: MetalGooseClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions Required")
                .font(.title3).bold()
            Divider()

            StatusRow(label: "Screen Recording", granted: client.screenRecordingGranted, grant: client.requestScreenRecording)
            StatusRow(label: "Accessibility", granted: client.accessibilityGranted, grant: client.requestAccessibility)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .cornerRadius(10)
    }
}

private struct StatusRow: View {
    let label: LocalizedStringKey
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Grant", action: grant)
            }
        }
    }
}

/// A titled card of settings (MetalGoose's `ConfigPanel`).
struct ConfigPanel<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Divider().overlay(Theme.edge)
            content
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PickerRow: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(minWidth: 160, maxWidth: 220)
        }
    }
}

/// A slider over a few chosen values rather than a range, so a setting that can only be 2 or 4 has two
/// stops and not three.
struct SliderRow: View {
    let label: LocalizedStringKey
    @Binding var value: Int
    let values: [Int]

    /// The stop the binding stands for: the highest one it reaches, or the first. A stored value the
    /// current choices cannot reach never shows a figure the pipeline is not running at.
    private var index: Int {
        values.lastIndex { $0 <= value } ?? 0
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            // One value would make the slider divide by its own zero width.
            if values.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(index) },
                        set: { value = values[min(values.count - 1, max(0, Int($0.rounded())))] }),
                    in: 0...Double(values.count - 1),
                    step: 1)
                .frame(minWidth: 110, maxWidth: 160)
            }
            Text("\(values[index])×")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 28, alignment: .trailing)
        }
    }
}

struct ToggleRow: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}
