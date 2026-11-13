import AppKit
import SwiftUI
import GooseCore

func applicationRendererLabel(_ application: SavedApplication, in bottle: Bottle) -> String {
    if URL(fileURLWithPath: application.executablePath).lastPathComponent.lowercased() == "hl.exe",
       application.arguments.contains(where: { $0.lowercased() == "-gl" }) { return "OpenGL" }
    return bottle.renderer == .dxmt ? "DXMT" : "WineD3D"
}

private struct LibraryEntry: Identifiable {
    let bottle: Bottle
    let application: SavedApplication
    var id: String { bottle.id.uuidString + application.id.uuidString }
}

struct LibraryView: View {
    @EnvironmentObject private var model: HubModel
    @AppStorage("library.grid") private var grid = true
    @AppStorage("library.sort") private var sort = "recent"
    @State private var favoritesOnly = false
    @State private var bottleID: UUID?

    private var allEntries: [LibraryEntry] {
        model.bottles.flatMap { bottle in bottle.applications.map { LibraryEntry(bottle: bottle, application: $0) } }
    }
    private var entries: [LibraryEntry] {
        allEntries.filter {
            (!favoritesOnly || $0.application.isFavorite) && (bottleID == nil || $0.bottle.id == bottleID)
                && (model.search.isEmpty || $0.application.name.localizedCaseInsensitiveContains(model.search)
                    || $0.bottle.name.localizedCaseInsensitiveContains(model.search))
        }.sorted { a, b in
            if sort == "recent" {
                let left = model.lastPlayed(a.application, in: a.bottle) ?? .distantPast
                let right = model.lastPlayed(b.application, in: b.bottle) ?? .distantPast
                if left != right { return left > right }
            }
            let order = a.application.name.localizedStandardCompare(b.application.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controls
            if model.bottles.isEmpty {
                EmptyPanel(symbol: "shippingbox", title: "No bottles",
                           message: "Create a bottle, then add a Windows game or run an installer.",
                           button: "Create Bottle") { model.showCreate = true }
            } else if entries.isEmpty {
                EmptyPanel(symbol: favoritesOnly ? "star" : "gamecontroller", title: "No applications",
                           message: allEntries.isEmpty ? "Choose a bottle in the sidebar to add a game or installer." : "Try another filter or search.",
                           button: (favoritesOnly || bottleID != nil || !model.search.isEmpty) ? "Clear filters" : "") {
                    favoritesOnly = false; bottleID = nil; model.search = ""
                }
            } else if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 16)], spacing: 16) {
                    ForEach(entries) { entry in ApplicationCard(application: entry.application, bottle: entry.bottle) }
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in ApplicationRow(application: entry.application, bottle: entry.bottle) }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { favoritesOnly.toggle() } label: {
                Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
                    .foregroundStyle(favoritesOnly ? Theme.accent : Theme.muted)
            }.buttonStyle(.borderless)
            Picker("Bottle", selection: $bottleID) {
                Text("All bottles").tag(nil as UUID?)
                ForEach(model.bottles) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().frame(maxWidth: 170)
            Spacer()
            Picker("Sort applications", selection: $sort) {
                Text("Recently played").tag("recent")
                Text("Name").tag("name")
            }.labelsHidden().frame(width: 155)
            HStack(spacing: 2) {
                layoutButton("square.grid.2x2", value: true, label: "Grid view")
                layoutButton("list.bullet", value: false, label: "List view")
            }.padding(3).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }.font(.system(size: 11))
    }

    private func layoutButton(_ symbol: String, value: Bool, label: String) -> some View {
        Button { grid = value } label: {
            Image(systemName: symbol).frame(width: 28, height: 24)
                .background(grid == value ? .white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).foregroundStyle(grid == value ? .white : Theme.muted).help(label).accessibilityLabel(label)
    }

}

struct ApplicationCard: View {
    @EnvironmentObject private var model: HubModel
    let application: SavedApplication
    let bottle: Bottle
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(application.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).help(application.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FavoriteButton(application: application, bottle: bottle)
            }
            Text(bottle.name).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack {
                Text(applicationRendererLabel(application, in: bottle)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                ApplicationPlayButton(application: application, bottle: bottle, showsTitle: true)
            }
        }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.edge))
            .contextMenu { ApplicationMenu(application: application, bottle: bottle) }
    }
}

struct FavoriteButton: View {
    @EnvironmentObject private var model: HubModel
    let application: SavedApplication
    let bottle: Bottle
    var body: some View {
        Button { model.toggleFavorite(application, in: bottle) } label: {
            Image(systemName: application.isFavorite ? "star.fill" : "star").font(.system(size: 12))
                .foregroundStyle(application.isFavorite ? Theme.accent : Theme.muted)
                .frame(width: 24, height: 24)
        }.buttonStyle(.plain).disabled(model.busy).help(application.isFavorite ? "Remove favorite" : "Add favorite")
            .accessibilityLabel(application.isFavorite ? "Remove favorite" : "Add favorite")
    }
}

struct ApplicationPlayButton: View {
    @EnvironmentObject private var model: HubModel
    let application: SavedApplication
    let bottle: Bottle
    var showsTitle = false
    private var available: Bool { FileManager.default.isReadableFile(atPath: application.executablePath) }
    var body: some View {
        let running = model.isRunning(application, in: bottle)
        Button { model.launch(application, in: bottle) } label: {
            HStack(spacing: 6) {
                Image(systemName: running ? "waveform" : !available ? "exclamationmark.triangle" : "play.fill")
                if showsTitle { Text(running ? "Running" : !available ? "File missing" : "Play") }
            }
        }.buttonStyle(AccentButtonStyle()).disabled(model.busy || running || !available)
            .help(!available ? "Executable not found. Edit the shortcut or locate the file in Finder." : running ? "This application is already running" : "Run \(application.name)")
            .accessibilityLabel(running ? "\(application.name) is running" : "Play \(application.name)")
    }
}

struct ApplicationMenu: View {
    @EnvironmentObject private var model: HubModel
    let application: SavedApplication
    let bottle: Bottle
    var body: some View {
        Button("Run") { model.launch(application, in: bottle) }
            .disabled(model.busy || model.isRunning(application, in: bottle) || !FileManager.default.isReadableFile(atPath: application.executablePath))
        Button(application.isFavorite ? "Remove Favorite" : "Add Favorite") { model.toggleFavorite(application, in: bottle) }
        Button("Edit…") { model.editing = ApplicationEdit(bottle: bottle, application: application) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: application.executablePath)]) }
        Divider()
        Button("Remove from Library") {
            model.perform("Removing \(application.name)…") { _ = try await model.service.removeApplication(bottleID: bottle.id, applicationID: application.id) }
        }
    }
}
