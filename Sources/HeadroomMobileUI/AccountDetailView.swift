import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// One account in full: the whole Pace card, the Burn-o-meter, the Macs reporting it, its past
/// weeks and recent sessions, and the session Live Activity.
struct AccountDetailView: View {
    var model: MobileModel
    var accountID: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        Group {
            if let account = model.reader.snapshot.account(accountID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PaceCardView(model: model, account: account, full: true)
                        if let setTracking = model.setTracking, account.reader(model)?.session.map({ !$0.isIdle }) == true {
                            let on = model.tracking.contains(account.id)
                            Button {
                                setTracking(account.id, !on)
                            } label: {
                                Label(on ? "Stop Tracking This Session" : "Track This Session on the Lock Screen",
                                      systemImage: on ? "stop.circle" : "livephoto")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        if let w = account.reader(model) { BurnPanel(provider: w, now: model.reader.now) }
                        MacsPanel(model: model, account: account)
                        HistoryPanels(model: model, account: account)
                        Toggle("Hide from Now", isOn: Binding(
                            get: { model.prefs.hiddenAccounts.contains(account.id) },
                            set: { on in if on { model.prefs.hiddenAccounts.insert(account.id) } else { model.prefs.hiddenAccounts.remove(account.id) } }))
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.cardSolid))
                    }
                    .padding(16)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .background(p.pageBackground)
                .navigationTitle(account.provider.displayName)
            } else {
                ContentUnavailableView("Account not found", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("It may have been removed from iCloud by its Mac."))
            }
        }
    }
}

extension MergedAccount {
    /// This account's entry in the widget feed (burn rates, charts).
    @MainActor func reader(_ model: MobileModel) -> WidgetProvider? { model.reader.feed.account(id) }
}

/// The Burn-o-meter: twin dials for the 5-hour session and the week.
struct BurnPanel: View {
    var provider: WidgetProvider
    var now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), copy = Copy(now: now)
        VStack(alignment: .leading, spacing: 10) {
            Text("Burn-o-meter").font(.headline).foregroundStyle(p.ink)
            HStack(spacing: 12) {
                if let s = provider.session {
                    dial("5-hour", burn: s.burn, text: copy.burn(s.burn, left: s.left, resetsAt: s.resetsAt, idle: s.isIdle,
                                                              runsOutAt: s.runsOutAt, leftAtReset: s.leftAtReset).text)
                }
                if let w = provider.week {
                    dial(w.caption.contains("month") ? "Month" : "Week", burn: w.burn,
                         text: copy.burn(w.burn, left: w.left, resetsAt: w.resetsAt).text)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
    }

    private func dial(_ label: String, burn: WidgetBurn, text: String) -> some View {
        let p = Palette(scheme)
        return VStack(spacing: 6) {
            SpeedDial(ratio: burn.ratio, average: burn.averageRatio, value: AccessoryMath.ratioText(burn.ratio), caption: label)
                .frame(height: 120)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(p.muted).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The Macs that report this account, and what each one last said.
struct MacsPanel: View {
    var model: MobileModel
    var account: MergedAccount
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 10) {
            Text(account.deviceIDs.count == 1 ? "From your Mac" : "From \(account.deviceIDs.count) Macs").font(.headline).foregroundStyle(p.ink)
            ForEach(account.deviceIDs, id: \.self) { id in
                if let d = model.device(id) {
                    HStack(spacing: 10) {
                        Image(systemName: d.isLaptop ? "laptopcomputer" : "desktopcomputer").frame(width: 24).foregroundStyle(p.muted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.subheadline.weight(.medium)).foregroundStyle(p.ink)
                            if let fault = account.deviceFaults[id] {
                                Text(fault.message(for: account.provider, lastGood: nil)).font(.caption).foregroundStyle(p.rose)
                            } else {
                                Text(DeviceText.status(d, now: model.reader.now)).font(.caption).foregroundStyle(p.muted)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
    }
}

/// Past weeks and recent 5-hour sessions, as the Activity tab draws them on the Mac.
struct HistoryPanels: View {
    var model: MobileModel
    var account: MergedAccount
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), now = model.reader.now
        let input = account.paceInput(now: now)
        let weeks = HistoryPresenter.pastWeeks(input, records: Array(account.history.weeks.suffix(7)),
                                               sessionHitsThisWindow: account.history.sessionHitsThisWindow,
                                               earlyResetAt: account.history.earlyResetAt, now: now)
        let sessions = HistoryPresenter.sessions(account.provider, sessions: account.history.recentSessions(now: now),
                                                 warnAt: account.policy.sessionAmber, now: now, calendar: .current, locale: .current)
        VStack(alignment: .leading, spacing: 16) {
            if !weeks.collecting {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Past weeks").font(.headline).foregroundStyle(p.ink)
                    Chips(chips: weeks.chips.map { ($0.color, $0.text) })
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(weeks.weeks.enumerated()), id: \.offset) { _, w in
                            WeekBar(column: w)
                        }
                    }
                    .frame(height: 110)
                }
            }
            if !sessions.bars.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("5-hour sessions").font(.headline).foregroundStyle(p.ink)
                    Chips(chips: sessions.chips.map { ($0.color, $0.text) })
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(sessions.bars.enumerated()), id: \.offset) { _, b in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(b.hitLimit ? p.rose : (b.inProgress ? p.tone(.plenty).text : p.tone(.plenty).text.opacity(0.6)))
                                    .frame(height: max(4, 70 * b.peak))
                                Text(b.dayLabel ?? " ").font(.system(size: 8, weight: .semibold)).foregroundStyle(p.muted2)
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(b.tooltip)
                        }
                    }
                    .frame(height: 90, alignment: .bottom)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(p.amber.opacity(0.6)).frame(height: 1).offset(y: -(14 + 70 * sessions.warnAt))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
    }
}

struct WeekBar: View {
    var column: WeekColumn
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.meterTrack)
                if let projected = column.projected {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(p.chartDash, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(height: 86 * min(projected, 1))
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(column.used >= 1 || column.ranOutHoursEarly != nil ? p.rose : p.azure.opacity(column.isCurrent ? 1 : 0.7))
                    .frame(height: max(3, 86 * min(column.used, 1)))
            }
            .frame(height: 86)
            Text(column.isCurrent ? "Now" : "\(Int((column.used * 100).rounded()))%").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(column.caption)
    }
}

struct Chips: View {
    var chips: [(PastWeeksModel.ChipDot, String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 5) {
                    Circle().fill(chip.0 == .rose ? p.rose : (chip.0 == .spark ? p.amber : p.azure)).frame(width: 6, height: 6)
                    Text(chip.1).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(p.chipFill))
            }
        }
    }
}

enum DeviceText {
    /// "Awake · synced 2m ago", "Asleep since 11:02 PM".
    @MainActor static func status(_ d: DeviceInfo, now: Date) -> String {
        let copy = Copy(now: now)
        switch d.state {
        case .sleeping: return "Asleep since \(copy.when(d.lastSeenAt))"
        case .quitting: return "Headroom quit at \(copy.when(d.lastSeenAt))"
        case .awake:
            if d.isQuiet(now: now) { return "Last heard from \(copy.when(d.lastSeenAt))" }
            let ago = TimeFormat.freshness(since: d.lastSeenAt, now: now)
            return ago == "now" ? "Awake · synced just now" : "Awake · synced \(ago) ago"
        }
    }
}
