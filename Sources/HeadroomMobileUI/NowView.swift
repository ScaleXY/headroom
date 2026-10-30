import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// One Pace card per account, the one that needs watching first at the top. Accounts no Mac is
/// signed in to (or hidden ones) wait at the bottom, collapsed.
struct NowView: View {
    var model: MobileModel
    var columns = 1
    @State private var showInactive = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let reader = model.reader
        ScrollView {
            VStack(spacing: 14) {
                if let state = EmptyState.current(model) {
                    EmptyStateView(model: model, state: state)
                } else {
                    Banners(model: model)
                    let grid = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columns)
                    LazyVGrid(columns: grid, spacing: 14) {
                        ForEach(model.orderedAccounts) { account in
                            NavigationLink(value: account.id) {
                                PaceCardView(model: model, account: account)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !model.hiddenOrInactive.isEmpty {
                        DisclosureGroup(isExpanded: $showInactive) {
                            VStack(spacing: 10) {
                                ForEach(model.hiddenOrInactive) { a in
                                    NavigationLink(value: a.id) { InactiveRow(model: model, account: a) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Not signed in on any Mac, or hidden (\(model.hiddenOrInactive.count))")
                                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(16)
        }
        .background(Palette(scheme).pageBackground)
        .navigationTitle("Now")
        .refreshable { await reader.reload() }
    }
}

/// An account no Mac reports now: its last reading, rolled forward by the clock.
struct InactiveRow: View {
    var model: MobileModel
    var account: MergedAccount
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 12) {
            BrandTile(provider: account.provider, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1)
                Text(lastSeen).font(.caption).foregroundStyle(p.muted)
            }
            Spacer()
            if model.prefs.hiddenAccounts.contains(account.id) {
                Image(systemName: "eye.slash").foregroundStyle(p.muted)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.cardSolid))
    }

    var lastSeen: String {
        let when = TimeFormat.freshness(since: account.updatedAt, now: model.reader.now)
        let base = when == "now" ? "Seen just now" : "Last seen \(when) ago"
        return account.projected ? base + " · renewed since" : base
    }
}

/// Notes above the cards: sample data, Macs gone quiet, an app update needed.
struct Banners: View {
    var model: MobileModel

    var body: some View {
        let r = model.reader
        VStack(spacing: 8) {
            if r.isDemo {
                Banner(symbol: "sparkles", tone: .plenty, text: "Sample data. Turn on sync in Headroom on your Mac to see your own.") {
                    Task { await model.setDemo(false) }
                } action: { "Use iCloud" }
            }
            if !r.isDemo, r.macsQuiet, let last = r.snapshot.lastHeard {
                Banner(symbol: "moon.zzz", tone: .tight,
                       text: "Your Macs haven't synced since \(Copy(now: r.now).when(last)). Readings resume when one is awake.")
            }
            if r.snapshot.tooNew > 0 {
                Banner(symbol: "arrow.down.circle", tone: .tight, text: "A Mac sent data this version can't read. Update Headroom on this device.")
            }
        }
    }
}

struct Banner: View {
    var symbol: String
    var tone: PacingState
    var text: String
    var onTap: (() -> Void)? = nil
    var action: (() -> String)? = nil
    @Environment(\.colorScheme) private var scheme

    init(symbol: String, tone: PacingState, text: String, onTap: (() -> Void)? = nil, action: (() -> String)? = nil) {
        self.symbol = symbol; self.tone = tone; self.text = text; self.onTap = onTap; self.action = action
    }

    var body: some View {
        let p = Palette(scheme), t = p.tone(tone)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(t.text)
            Text(text).font(.footnote.weight(.medium)).foregroundStyle(p.ink).frame(maxWidth: .infinity, alignment: .leading)
            if let onTap, let action {
                Button(action(), action: onTap).font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.text.opacity(0.12)))
    }
}

extension Palette {
    /// Behind the cards: the Mac Settings window's backdrop.
    var pageBackground: Color { dark ? Color(red: 0.08, green: 0.086, blue: 0.10) : Color(red: 0.95, green: 0.95, blue: 0.96) }
}
