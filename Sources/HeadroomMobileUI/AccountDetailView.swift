import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// One account in full: the whole Limits card, the Burn-o-meter, the Macs reporting it, its past
/// weeks, and the session Live Activity.
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

/// Past weeks for one account, as the Activity tab draws them on the Mac: the heading, the card and
/// its legend. (Recent 5-hour sessions moved to the Limits card's lane; their count is a chip here.)
struct HistoryPanels: View {
    var model: MobileModel
    var account: MergedAccount

    var body: some View {
        let weeks = Self.weeks(account, now: model.reader.now)
        if !weeks.collecting {
            VStack(alignment: .leading, spacing: 10) {
                PastWeeksHeading()
                PastWeeksCard(model: weeks, title: account.provider.displayName)
                PastWeeksLegend()
            }
        }
    }

    /// The account's finished weeks beside this one, with the last seven days' 5-hour sessions
    /// counted when it has a 5-hour limit.
    @MainActor static func weeks(_ account: MergedAccount, now: Date) -> PastWeeksModel {
        let input = account.paceInput(now: now)
        let sessions = input.reading?.session != nil ? account.history.recentSessions(now: now) : nil
        return HistoryPresenter.pastWeeks(input, records: Array(account.history.weeks.suffix(7)),
                                          sessionHitsThisWindow: account.history.sessionHitsThisWindow,
                                          earlyResetAt: account.history.earlyResetAt, sessions: sessions, now: now)
    }
}

struct PastWeeksHeading: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .firstTextBaseline) {
            Text("Past weeks").font(.headline).foregroundStyle(p.ink)
            Spacer()
            Text("used by each renewal").font(.caption.weight(.medium)).foregroundStyle(p.muted)
        }
        .padding(.horizontal, 3)
    }
}

/// One account's renewal weeks (redesign §5): each a column of 8 meter cells, lit for the share
/// used in the provider's tone; a week that ran out is rose with how early above it; this week is
/// dimmer with a dashed outline, its projection outlined above it.
struct PastWeeksCard: View {
    var model: PastWeeksModel
    var title: String
    @Environment(\.colorScheme) private var scheme

    static let cells = 8

    var body: some View {
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                BrandTile(provider: model.provider, size: 20)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 6)
                Chips(chips: model.chips.map { ($0.color, $0.text) })
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(model.weeks.enumerated()), id: \.offset) { i, week in
                    WeekCells(column: week, provider: model.provider)
                    if let change = model.planChange, change.after == i {
                        PlanDivider(pill: change.pill)
                    }
                }
            }
        }
        .padding(14)
        .signatureCard(model.provider)
    }

    /// Lit cells for a share used: rounded, at least one for any real use, all of them when it ran out.
    static func litCells(used: Double, ranOut: Bool, cells n: Int = cells) -> Int {
        if ranOut { return n }
        let u = min(max(used, 0), 1)
        return min(n, max(Int((u * Double(n)).rounded()), u >= 0.03 ? 1 : 0))
    }
}

/// One week's column: the label above (NOW, or −31H when it ran out), the cells, the markers under it.
struct WeekCells: View {
    var column: WeekColumn
    var provider: Provider
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), n = PastWeeksCard.cells
        let ranOut = column.used >= 1 || column.ranOutHoursEarly != nil
        let lit = PastWeeksCard.litCells(used: column.used, ranOut: ranOut)
        let projected = column.isCurrent ? max(lit, PastWeeksCard.litCells(used: column.projected ?? column.used, ranOut: false)) : lit
        let litColor = ranOut ? p.rose : p.providerTone(provider, column.isCurrent ? ProviderTone.pastWeekCurrent : ProviderTone.pastWeek)
        let unlit = p.ink.opacity(0.06)
        VStack(spacing: 5) {
            Group {
                if column.isCurrent {
                    Text("NOW").foregroundStyle(p.muted)
                } else if let early = column.ranOutHoursEarly {
                    Text("−\(early)H").foregroundStyle(p.rose)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 9, weight: .bold)).tracking(0.5)
            VStack(spacing: 2) {
                ForEach((0..<n).reversed(), id: \.self) { c in
                    let cell = RoundedRectangle(cornerRadius: 2, style: .continuous)
                    ZStack {
                        cell.fill(c < lit ? litColor : unlit)
                        if c < lit, column.isCurrent {
                            cell.inset(by: 0.4).stroke(p.ink.opacity(0.6), style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                        } else if c >= lit, c < projected {
                            cell.inset(by: 0.4).stroke(p.ink.opacity(0.32), style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                        }
                    }
                    .frame(height: 6)
                }
            }
            HStack(spacing: 2) {
                if column.sessionHits > 0 {
                    PauseMark(color: p.muted)
                    if column.sessionHits > 1 { Text("\(column.sessionHits)").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.muted) }
                }
                if column.earlyResets > 0 { Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).foregroundStyle(Self.spark) }
            }
            .frame(height: 10)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.caption)
    }

    static let spark = Color(.sRGB, red: 0x8C / 255.0, green: 0xC2 / 255.0, blue: 1, opacity: 1)
}

/// ‖: a week with sessions that hit the 5-hour limit.
struct PauseMark: View {
    var color: Color
    var body: some View {
        HStack(spacing: 1.6) {
            RoundedRectangle(cornerRadius: 0.8).fill(color).frame(width: 2.4, height: 8)
            RoundedRectangle(cornerRadius: 0.8).fill(color).frame(width: 2.4, height: 8)
        }
    }
}

/// The line between weeks where the plan changed, with the new plan's pill.
struct PlanDivider: View {
    var pill: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        LinearGradient(colors: [p.ink.opacity(p.dark ? 0.4 : 0.3), p.ink.opacity(0.04)], startPoint: .top, endPoint: .bottom)
            .frame(width: 1, height: 84)
            .overlay(alignment: .topLeading) {
                Text(pill.uppercased()).font(.system(size: 8.5, weight: .bold)).tracking(0.6).foregroundStyle(p.ink.opacity(0.6))
                    .fixedSize().offset(x: 4, y: 0)
            }
            .padding(.bottom, 15)
    }
}

/// ‖ hit 5-hour limit · ✦ early reset · ran out (hours early) · projected.
struct PastWeeksLegend: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), color = p.ink.opacity(0.5)
        FlowLayout(spacing: 12, lineSpacing: 6) {
            HStack(spacing: 5) { PauseMark(color: color); Text("hit 5-hour limit") }
            HStack(spacing: 5) { Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(WeekCells.spark); Text("early reset") }
            HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(p.rose).frame(width: 12, height: 6); Text("ran out (hours early)") }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.8).stroke(p.ink.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5])).frame(width: 12, height: 6)
                Text("projected")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 3)
    }
}

struct Chips: View {
    var chips: [(PastWeeksModel.ChipDot, String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 5) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 5) {
                    if chip.0 == .spark {
                        Image(systemName: "sparkle").font(.system(size: 7, weight: .bold)).foregroundStyle(WeekCells.spark)
                    } else {
                        Circle().fill(color(chip.0, p)).frame(width: 5, height: 5)
                    }
                    Text(chip.1).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(p.ink).lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(p.chipFill))
            }
        }
        .fixedSize()
    }

    private func color(_ dot: PastWeeksModel.ChipDot, _ p: Palette) -> Color {
        switch dot {
        case .rose: p.rose
        case .azure: p.azure
        case .spark: WeekCells.spark
        case .amber: p.amber
        case .muted: p.ink.opacity(0.4)
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
