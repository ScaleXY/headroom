import HeadroomKit
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// The app's sections: tabs on a phone (and the Duo's outer screen), a sidebar when there's room
/// (iPad, the Duo unfolded).
public enum MobileSection: String, CaseIterable, Hashable, Sendable {
    case now, activity, macs, settings

    public var title: String {
        switch self {
        case .now: "Now"
        case .activity: "Activity"
        case .macs: "Macs"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .now: "gauge.with.dots.needle.67percent"
        case .activity: "chart.bar.xaxis"
        case .macs: "laptopcomputer"
        case .settings: "gearshape"
        }
    }
}

/// Where the sidebar points: a section, or one account.
enum SidebarItem: Hashable {
    case section(MobileSection)
    case account(String)
}

/// The whole app. Layout follows the width it's given, never the device model, so folding and
/// unfolding a Duo (or resizing a Stage Manager window) keeps the place.
public struct HeadroomRootView: View {
    @Bindable var model: MobileModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @SceneStorage("section") private var section: MobileSection = .now
    @SceneStorage("sidebar.account") private var sidebarAccount: String?
    @State private var path: [String] = []
    /// A link to open at launch (UI tests and screenshots pass `-HeadroomOpen <url>`).
    var launchURL: URL?

    public init(model: MobileModel, launchURL: URL? = nil) { self.model = model; self.launchURL = launchURL }

    var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    public var body: some View {
        Group {
            if compact { tabs } else { split }
        }
        .preferredColorScheme(model.prefs.appearance.scheme)
        .tint(Color.accentColor)
        .onOpenURL(perform: open)
        .task { if let launchURL { open(launchURL) } }
    }

    // MARK: Phone

    private var tabs: some View {
        TabView(selection: $section) {
            Tab(MobileSection.now.title, systemImage: MobileSection.now.symbol, value: MobileSection.now) {
                NavigationStack(path: $path) {
                    NowView(model: model)
                        .navigationDestination(for: String.self) { AccountDetailView(model: model, accountID: $0) }
                }
            }
            Tab(MobileSection.activity.title, systemImage: MobileSection.activity.symbol, value: MobileSection.activity) {
                NavigationStack { ActivityView(model: model) }
            }
            Tab(MobileSection.macs.title, systemImage: MobileSection.macs.symbol, value: MobileSection.macs) {
                NavigationStack { MacsView(model: model) }
            }
            Tab(MobileSection.settings.title, systemImage: MobileSection.settings.symbol, value: MobileSection.settings) {
                NavigationStack { MobileSettingsView(model: model) }
            }
        }
    }

    // MARK: iPad and the unfolded Duo

    private var selection: Binding<SidebarItem?> {
        Binding {
            sidebarAccount.map { SidebarItem.account($0) } ?? .section(section)
        } set: { item in
            switch item {
            case .section(let s): section = s; sidebarAccount = nil
            case .account(let id): sidebarAccount = id
            case nil: break
            }
        }
    }

    private var split: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(MobileSection.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.symbol).tag(SidebarItem.section(s))
                    }
                }
                if !model.orderedAccounts.isEmpty {
                    Section("Accounts") {
                        ForEach(model.orderedAccounts) { a in
                            AccountSidebarRow(model: model, account: a).tag(SidebarItem.account(a.id))
                        }
                    }
                }
            }
            .navigationTitle("Headroom")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            NavigationStack {
                if let id = sidebarAccount {
                    AccountDetailView(model: model, accountID: id)
                } else {
                    switch section {
                    case .now: NowView(model: model, columns: 2)
                    case .activity: ActivityView(model: model)
                    case .macs: MacsView(model: model)
                    case .settings: MobileSettingsView(model: model)
                    }
                }
            }
        }
    }

    /// `headroom://account/<id>` (widgets, the Live Activity) and `headroom://activity`.
    private func open(_ url: URL) {
        guard url.scheme == "headroom" else { return }
        switch url.host() {
        case "account":
            let id = url.pathComponents.dropFirst().joined(separator: "/")
            guard !id.isEmpty else { return }
            if compact { section = .now; path = [id] } else { sidebarAccount = id }
        case "activity":
            section = .activity; sidebarAccount = nil
        default:
            section = .now; sidebarAccount = nil
        }
    }
}

struct AccountSidebarRow: View {
    var model: MobileModel
    var account: MergedAccount
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = model.reader.feed.account(account.id)
        HStack(spacing: 10) {
            BrandTile(provider: account.provider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let w = p?.week {
                    Text("\(Copy(now: model.reader.now).percent(w.left)) left · \(w.state.word)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
