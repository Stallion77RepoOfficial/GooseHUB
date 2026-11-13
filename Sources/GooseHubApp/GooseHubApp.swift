import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GooseCore

@main
struct GooseHubApp: App {
    @StateObject private var model = HubModel()
    @StateObject private var setup = EngineSetupModel()

    var body: some Scene {
        WindowGroup("Goose HUB Adrenalin Edition") {
            Group {
                if setup.installed { HubShell() }
                else { EngineSetupView(setup: setup) }
            }.environmentObject(model)
                .frame(minWidth: 1080, minHeight: 720)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await model.refresh(); await setup.check() }
                .onChange(of: setup.installed) { _, installed in
                    if installed { Task { await model.refresh(checkEngines: true) } }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { model.showCreate = true }.keyboardShortcut("n").disabled(!setup.installed)
                Button("Refresh") { Task { await model.refresh(checkEngines: true); await setup.check() } }.keyboardShortcut("r")
                Button("Library") { model.selectedBottleID = nil; model.route = .library }.keyboardShortcut("1")
                Button("Sessions") { model.selectedBottleID = nil; model.route = .sessions }.keyboardShortcut("2")
            }
        }
    }
}

/// The Goose HUB logo, as the app bundle carries it. A plain `swift run` has no
/// bundle around it and falls back to the bird symbol.
struct BrandMark: View {
    let size: CGFloat
    private static let logo = Bundle.main.url(forResource: "GooseHUB-logo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let logo = Self.logo {
            Image(nsImage: logo).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            Image(systemName: "bird.fill").font(.system(size: size * 0.8, weight: .semibold)).foregroundStyle(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 1, green: 0.22, blue: 0.26)
    static let background = Color(red: 0.052, green: 0.058, blue: 0.071)
    static let panel = Color(red: 0.085, green: 0.092, blue: 0.11)
    static let edge = Color.white.opacity(0.075)
    static let muted = Color(red: 0.56, green: 0.60, blue: 0.66)
    static let success = Color(red: 0.40, green: 0.83, blue: 0.66)
}

enum HubRoute: String, CaseIterable {
    case library = "Library", metalGoose = "MetalGoose", engines = "Engines", sessions = "Sessions"
    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .metalGoose: return "display.2"
        case .engines: return "cpu"
        case .sessions: return "list.bullet.rectangle"
        }
    }
}

struct ApplicationEdit: Identifiable {
    let bottle: Bottle
    let application: SavedApplication
    var id: UUID { application.id }
}

@MainActor
final class HubModel: ObservableObject {
    let service = HubService()
    let metalGoose = MetalGooseClient()
    @Published var bottles: [Bottle] = []
    @Published var engineStatus: EngineStatus?
    @Published var runtimeSettings = RuntimeSettings()
    @Published var records: [LaunchRecord] = []
    @Published var selectedBottleID: UUID?
    @Published var route: HubRoute = .library
    @Published var showCreate = false
    @Published var showRun = false
    @Published var renaming: Bottle?
    @Published var duplicating: Bottle?
    @Published var deleting: Bottle?
    @Published var editing: ApplicationEdit?
    @Published var error: String?
    @Published var busy = false
    @Published var activity = ""
    @Published var search = ""
    private var refreshing = false

    var selectedBottle: Bottle? { bottles.first { $0.id == selectedBottleID } }
    var running: [LaunchRecord] { records.filter { $0.status == .running } }

    func refresh(checkEngines: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if engineStatus == nil || checkEngines {
            let status = await service.diagnose()
            if engineStatus != status { engineStatus = status }
        }
        do {
            let settings = try await service.runtimeSettings()
            if runtimeSettings != settings { runtimeSettings = settings }
            let updated = try await service.listBottles()
            if bottles != updated { bottles = updated }
        }
        catch { self.error = error.localizedDescription }
        // Earlier launches come from the bottles' logs, so the list survives quitting Goose HUB.
        var launches = await service.launches()
        for bottle in bottles {
            if let history = try? await service.launchHistory(bottleID: bottle.id) { launches += history }
        }
        var seen = Set<UUID>()
        let updatedRecords = launches.filter { seen.insert($0.id).inserted }.sorted { $0.startedAt > $1.startedAt }
        if records != updatedRecords { records = updatedRecords }
        if bottles.contains(where: { $0.metalGoose.enabled }) { metalGoose.prepare() }
    }

    func perform(_ label: String, operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; activity = label
        Task {
            defer { busy = false; activity = "" }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }

    func create(name: String, architecture: BottleArchitecture, renderer: Renderer, synchronization: SynchronizationMode, windowsVersion: WindowsVersion) {
        perform("Creating \(name)…") {
            let bottle = try await self.service.createBottle(name: name, architecture: architecture, renderer: renderer,
                                                             synchronization: synchronization, windowsVersion: windowsVersion)
            self.selectedBottleID = bottle.id
            self.route = .library
        }
    }

    func save(_ bottle: Bottle) {
        perform("Saving settings…") { try await self.service.updateBottle(bottle) }
    }

    /// Saved without the busy state: a bottle starts or stops using MetalGoose while its game runs.
    func setMetalGoose(_ enabled: Bool, for bottle: Bottle) {
        let settings = MetalGooseSettings(enabled: enabled)
        if let index = bottles.firstIndex(where: { $0.id == bottle.id }) { bottles[index].metalGoose = settings }
        if enabled, let launch = running.first(where: { $0.bottleID == bottle.id }) { metalGoose.follow(launch) }
        metalGoose.setEnabled(enabled, bottleID: bottle.id)
        Task {
            do { _ = try await service.updateMetalGoose(bottleID: bottle.id, settings: settings) }
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }

    func rename(_ bottle: Bottle, to name: String) {
        perform("Renaming \(bottle.name)…") { _ = try await self.service.renameBottle(bottleID: bottle.id, name: name) }
    }

    func duplicate(_ bottle: Bottle, as name: String) {
        perform("Duplicating \(bottle.name)…") {
            let copy = try await self.service.duplicateBottle(bottleID: bottle.id, name: name)
            self.selectedBottleID = copy.id
        }
    }

    func delete(_ bottle: Bottle) {
        perform("Moving \(bottle.name) to the Trash…") {
            try await self.service.deleteBottle(bottleID: bottle.id)
            if self.selectedBottleID == bottle.id { self.selectedBottleID = nil }
        }
    }

    func runTool(_ tool: WineTool, in bottle: Bottle) {
        perform("Starting \(tool.title)…") { _ = try await self.service.runTool(bottleID: bottle.id, tool: tool) }
    }

    func setReducedX87Precision(_ enabled: Bool) {
        perform("Saving runtime settings…") {
            var settings = try await self.service.runtimeSettings()
            settings.reducedX87Precision = enabled
            try await self.service.updateRuntimeSettings(settings)
        }
    }

    func setLegacyOpenGLBatching(_ enabled: Bool) {
        perform("Saving runtime settings…") {
            var settings = try await self.service.runtimeSettings()
            settings.legacyOpenGLBatching = enabled
            try await self.service.updateRuntimeSettings(settings)
        }
    }

    func update(_ edit: ApplicationEdit, name: String, arguments: [String]) {
        perform("Saving \(name)…") {
            _ = try await self.service.updateApplication(bottleID: edit.bottle.id, applicationID: edit.application.id,
                                                         name: name, arguments: arguments)
        }
    }

    func launch(_ application: SavedApplication, in bottle: Bottle) {
        guard !isRunning(application, in: bottle) else { return }
        perform("Starting \(application.name)…") {
            let record = try await self.service.runApplication(bottleID: bottle.id, applicationID: application.id)
            self.followWithMetalGoose(record)
        }
    }

    func isRunning(_ application: SavedApplication, in bottle: Bottle) -> Bool {
        running.contains { $0.bottleID == bottle.id && $0.executablePath == application.executablePath }
    }

    func lastPlayed(_ application: SavedApplication, in bottle: Bottle) -> Date? {
        records.first { $0.bottleID == bottle.id && $0.executablePath == application.executablePath }?.startedAt
    }

    func toggleFavorite(_ application: SavedApplication, in bottle: Bottle) {
        perform("Updating favorites…") {
            _ = try await self.service.setApplicationFavorite(bottleID: bottle.id, applicationID: application.id,
                                                              isFavorite: !application.isFavorite)
        }
    }

    func run(_ executable: URL, arguments: [String], addShortcut: Bool, in bottle: Bottle) {
        perform("Starting \(executable.lastPathComponent)…") {
            if addShortcut {
                _ = try await self.service.addApplication(bottleID: bottle.id, name: executable.deletingPathExtension().lastPathComponent,
                                                          executable: executable, arguments: arguments)
            }
            let record = try await self.service.run(bottleID: bottle.id, executable: executable, arguments: arguments)
            self.followWithMetalGoose(record)
        }
    }

    private func followWithMetalGoose(_ record: LaunchRecord) {
        guard bottles.first(where: { $0.id == record.bottleID })?.metalGoose.enabled == true else { return }
        metalGoose.follow(record)
    }

    func chooseApplication(in bottle: Bottle) {
        Task {
            guard let url = await Self.chooseExecutable() else { return }
            perform("Adding \(url.lastPathComponent)…") {
                _ = try await self.service.addApplication(bottleID: bottle.id, name: url.deletingPathExtension().lastPathComponent, executable: url)
            }
        }
    }

    func openDrive(_ bottle: Bottle) {
        Task {
            do {
                let directory = try await service.prefixDirectory(bottle.id)
                NSWorkspace.shared.open(directory.appendingPathComponent("drive_c"))
            } catch { self.error = error.localizedDescription }
        }
    }

    static func chooseExecutable() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows Program or Installer"
        panel.message = "Choose an .exe or .msi file."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["exe", "msi"].compactMap { .init(filenameExtension: $0) }
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}
