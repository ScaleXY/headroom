import HeadroomKit
import HeadroomWidgetUI
import SwiftUI

/// Why there's nothing to show yet, in the order to fix it.
enum EmptyState: Equatable {
    case loading
    case noICloud
    case waitingForMac
    case noAccounts

    @MainActor static func current(_ model: MobileModel) -> EmptyState? {
        let r = model.reader
        if r.isDemo { return r.accounts.isEmpty ? .loading : nil }
        if !r.loaded { return .loading }
        if model.iCloud == .noAccount || model.iCloud == .restricted { return .noICloud }
        if !r.hasMac { return .waitingForMac }
        if model.visibleAccounts.isEmpty && model.hiddenOrInactive.isEmpty { return .noAccounts }
        return nil
    }
}

struct EmptyStateView: View {
    var model: MobileModel
    var state: EmptyState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(spacing: 18) {
            HeadroomMarkView(size: 64).padding(.top, 24)
            switch state {
            case .loading:
                ProgressView()
                Text("Reading from iCloud…").font(.subheadline).foregroundStyle(p.muted)
            case .noICloud:
                Text("Sign in to iCloud").font(.title2.weight(.semibold)).foregroundStyle(p.ink)
                Text("Use the same Apple Account as the Mac running Headroom. Your readings travel through your own private iCloud, and nowhere else.")
                    .font(.subheadline).foregroundStyle(p.muted).multilineTextAlignment(.center)
                #if os(iOS)
                Button("Open Settings") {
                    if let url = URL(string: "App-prefs:") { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                #endif
                explore
            case .waitingForMac:
                Text("Waiting for your Mac").font(.title2.weight(.semibold)).foregroundStyle(p.ink)
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Install Headroom on your Mac", "It reads your Claude and Codex limits and sits in the menu bar.")
                    step(2, "Turn on sync", "In Headroom's Settings → iPhone & Watch, choose Turn On.")
                    step(3, "Keep this open", "Your readings appear here within a minute or two.")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(p.cardSolid))
                Text(PrivacyPromise.headline).font(.footnote.weight(.semibold)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                explore
            case .noAccounts:
                Text("No accounts yet").font(.title2.weight(.semibold)).foregroundStyle(p.ink)
                Text("Your Mac is syncing, but hasn't read Claude or Codex yet. Check that one is signed in on that Mac.")
                    .font(.subheadline).foregroundStyle(p.muted).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private var explore: some View {
        Button("Explore with Sample Data") { Task { await model.setDemo(true) } }
            .buttonStyle(.bordered)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        let p = Palette(scheme)
        return HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline.monospacedDigit()).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(Circle().fill(p.azure))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink)
                Text(detail).font(.footnote).foregroundStyle(p.muted)
            }
        }
    }
}
