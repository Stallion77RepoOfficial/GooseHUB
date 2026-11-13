import AppKit
import Combine
import SwiftUI
import GooseCore

struct HubShell: View {
    @EnvironmentObject private var model: HubModel
    private let poll = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(Theme.edge).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                Rectangle().fill(Theme.edge).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let bottle = model.selectedBottle { BottleDetail(bottle: bottle) }
                        else {
                            switch model.route {
                            case .library: LibraryView()
                            case .metalGoose: MetalGooseView(client: model.metalGoose)
                            case .engines: EnginesView()
                            case .sessions: SessionsView()
                            }
                        }
                    }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.busy {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.mini)
                        Text(model.activity).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Spacer()
                    }.padding(.horizontal, 30).padding(.vertical, 10).background(Theme.panel.opacity(0.45))
                }
            }.background(Theme.background)
        }
        .background(Theme.background)
        .sheet(isPresented: $model.showCreate) { CreateBottleSheet() }
        .sheet(isPresented: $model.showRun) { if let bottle = model.selectedBottle { RunCommandSheet(bottle: bottle) } }
        .sheet(item: $model.renaming) { bottle in
            NameSheet(title: "Rename Bottle", action: "Rename", name: bottle.name) { model.rename(bottle, to: $0) }
        }
        .sheet(item: $model.duplicating) { bottle in
            NameSheet(title: "Duplicate \(bottle.name)", action: "Duplicate", name: "\(bottle.name) Copy") { model.duplicate(bottle, as: $0) }
        }
        .sheet(item: $model.editing) { EditApplicationSheet(edit: $0) }
        .confirmationDialog("Move \(model.deleting?.name ?? "") to the Trash?",
                            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }),
                            presenting: model.deleting) { bottle in
            Button("Move to Trash", role: .destructive) { model.delete(bottle) }
        } message: { _ in
            Text("Running programs will stop. Installed files move to Trash.")
        }
        .alert("Error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onReceive(poll) { _ in Task { await model.refresh() } }
        .modifier(MetalGooseAlert(client: model.metalGoose))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Goose HUB").font(.system(size: 16, weight: .bold))
                    Text("Adrenalin Edition").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }.padding(.top, 40).padding(.bottom, 26).padding(.horizontal, 22)
            ForEach(HubRoute.allCases, id: \.self) { route in
                Button {
                    model.route = route; model.selectedBottleID = nil
                } label: {
                    HStack {
                        Image(systemName: route.symbol).frame(width: 22)
                        Text(route.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if route == .sessions && !model.running.isEmpty { Text("\(model.running.count)").font(.caption2).foregroundStyle(Theme.accent) }
                    }.foregroundStyle(model.route == route && model.selectedBottleID == nil ? .white : Theme.muted)
                        .padding(11).background(model.route == route && model.selectedBottleID == nil ? Theme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 3)
            }
            HStack {
                Text("Bottles").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { model.showCreate = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New Bottle")
            }.foregroundStyle(Theme.muted).padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.bottles) { bottle in
                        Button { model.selectedBottleID = bottle.id; model.route = .library } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox").foregroundStyle(model.selectedBottleID == bottle.id ? Theme.accent : Theme.muted)
                                Text(bottle.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(bottle.applications.count)").font(.system(size: 10)).foregroundStyle(Theme.muted)
                            }.padding(11).background(model.selectedBottleID == bottle.id ? .white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).contextMenu { BottleMenu(bottle: bottle) }
                    }
                    if model.bottles.isEmpty {
                        Text("No bottles yet.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                    }
                }.padding(.horizontal, 12)
            }
        }.background(Color(red: 0.069, green: 0.074, blue: 0.088))
    }

    private var topbar: some View {
        HStack {
            Text(model.selectedBottle?.name ?? model.route.rawValue).font(.system(size: 20, weight: .semibold))
            Spacer()
            if model.route == .library {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Search Applications", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Clear search")
                    }
                }.font(.system(size: 11)).padding(9).frame(width: 210).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            }
            Button { model.showCreate = true } label: { Label("New Bottle", systemImage: "plus") }
                .buttonStyle(AccentButtonStyle()).disabled(model.busy)
        }.padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 16)
    }

}

/// MetalGoose's alert, wherever Goose HUB is when it has something to say.
private struct MetalGooseAlert: ViewModifier {
    @ObservedObject var client: MetalGooseClient
    func body(content: Content) -> some View {
        content.alert("MetalGoose", isPresented: Binding(get: { client.alert != nil }, set: { if !$0 { client.alert = nil } }),
                      presenting: client.alert) { _ in
            Button("OK", role: .cancel) { client.alert = nil }
        } message: { message in
            Text(verbatim: message)
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 9)
            .foregroundStyle(.white).background(Theme.accent.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.38)
    }
}

struct EmptyPanel: View {
    let symbol: String; let title: String; let message: String; let button: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Theme.muted).padding(.bottom, 4)
            Text(title).font(.system(size: 16, weight: .semibold))
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 390)
            }
            if !button.isEmpty { Button(button, action: action).buttonStyle(AccentButtonStyle()).padding(.top, 5) }
        }.padding(38).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.edge))
    }
}
