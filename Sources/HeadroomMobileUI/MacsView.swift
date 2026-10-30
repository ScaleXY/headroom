import HeadroomKit
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// The Macs that sync: when each was last heard from, its Headroom version, and the accounts it reports.
struct MacsView: View {
    var model: MobileModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.reader.snapshot.devices.isEmpty {
                    if let state = EmptyState.current(model) { EmptyStateView(model: model, state: state) }
                }
                ForEach(model.reader.snapshot.devices) { d in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: d.isLaptop ? "laptopcomputer" : "desktopcomputer")
                                .font(.title2).foregroundStyle(d.isQuiet(now: model.reader.now) ? p.muted : p.ink).frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.headline).foregroundStyle(p.ink)
                                Text(DeviceText.status(d, now: model.reader.now)).font(.caption).foregroundStyle(p.muted)
                            }
                            Spacer()
                            Text("Headroom \(d.appVersion)").font(.caption2.weight(.medium)).foregroundStyle(p.muted2)
                        }
                        ForEach(d.accounts, id: \.self) { id in
                            if let a = model.reader.snapshot.account(id) {
                                HStack(spacing: 8) {
                                    BrandTile(provider: a.provider, size: 16)
                                    Text(a.label).font(.footnote.weight(.medium)).foregroundStyle(p.ink).lineLimit(1)
                                    Spacer()
                                    if let fault = d.faults[id] {
                                        Text(fault.code.replacingOccurrences(of: "_", with: " ")).font(.caption2.weight(.semibold)).foregroundStyle(p.rose)
                                    }
                                }
                                .padding(.leading, 48)
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
                }
                if !model.reader.snapshot.devices.isEmpty {
                    Text("A Mac that stops syncing stays listed with its last readings. Remove it from iCloud in Headroom on that Mac, under Settings → iPhone & Watch.")
                        .font(.caption).foregroundStyle(p.muted).padding(.horizontal, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(p.pageBackground)
        .navigationTitle("Macs")
    }
}
