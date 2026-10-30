import HeadroomKit
import HeadroomPresent
import HeadroomSync
import HeadroomWidgetUI
import SwiftUI

/// The Pace card, as the Mac's popover draws it, from the same `Presenter`: header, the 5-hour
/// panel, what's left, the meter, the glide, the verdict, callouts and details.
struct PaceCardView: View {
    var model: MobileModel
    var account: MergedAccount
    var full = false
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 46

    var body: some View {
        let now = model.reader.now
        let presenter = Presenter(now: now, calendar: .current, locale: .current, policy: account.policy)
        let card = presenter.paceCard(account.paceInput(now: now))
        let feed = model.reader.feed.account(account.id)
        let p = Palette(scheme)
        VStack(alignment: .leading, spacing: 12) {
            header(card, p: p)
            if let fault = card.fault { FaultBanner(model: fault) }
            if let module = card.sessionModule, module.onTop { SessionModuleView(module: module, chart: feed?.session?.chart) }
            if let banner = card.session { SessionBannerView(banner: banner) }
            if let hero = card.hero {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(hero.percentLeft)%").font(.system(size: heroSize, weight: .semibold).monospacedDigit()).foregroundStyle(p.ink)
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hero.label).font(.subheadline.weight(.medium)).foregroundStyle(p.muted).lineLimit(1)
                        HStack(spacing: 4) {
                            if hero.hourglass { Hourglass(color: p.tone(.plenty).text, height: 11) }
                            Text("\(hero.renewCaption) · in \(hero.renewValue)").font(.footnote.weight(.medium)).foregroundStyle(p.muted2)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if let meter = card.meter, card.showsMeter {
                CellMeter(state: meter.state, cells: meter.cells, caret: meter.caret, height: 13, dim: meter.opacity < 1)
            }
            if card.showsGlide, let chart = feed?.week?.chart, let state = card.meter?.state {
                GlideChartView(chart: chart, tone: p.tone(state)).frame(height: full ? 170 : 120)
            }
            if let verdict = card.verdict {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verdict.primary).font(.subheadline.weight(.medium)).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
                    if full, !verdict.secondary.isEmpty {
                        Text(verdict.secondary).font(.footnote).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let module = card.sessionModule, !module.onTop { SessionModuleView(module: module, chart: feed?.session?.chart) }
            if let callout = card.callout { CalloutView(callout: callout) }
            if full, !card.rows.isEmpty {
                VStack(spacing: 8) { ForEach(Array(card.rows.enumerated()), id: \.offset) { DetailRow(row: $0.element) } }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.groupBorder, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(card))
    }

    private func header(_ card: PaceCardModel, p: Palette) -> some View {
        HStack(spacing: 10) {
            BrandTile(provider: account.provider, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.email ?? account.provider.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(p.ink).lineLimit(1)
                    if let plan = card.plan { PlanPill(provider: account.provider, text: plan) }
                }
                HStack(spacing: 5) {
                    Dot(color: freshnessColor(card.freshness.status, p: p), size: 6)
                    Text(freshnessText(card)).font(.caption).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let state = card.meter?.state, let title = card.verdict?.title { StateChip(state: state, title: title) }
        }
    }

    private func freshnessText(_ card: PaceCardModel) -> String {
        let source = account.deviceIDs.count > 1 ? "\(account.deviceIDs.count) Macs" : (account.sourceDevice ?? "your Mac")
        let ago = card.freshness.text
        return (ago == "now" ? "Updated just now" : "Updated \(ago) ago") + " · \(source)"
    }

    private func freshnessColor(_ s: Freshness.Status, p: Palette) -> Color {
        switch s {
        case .fresh: p.ok
        case .stale: p.stale
        case .error: p.rose
        }
    }

    private func spoken(_ card: PaceCardModel) -> String {
        var parts = ["\(account.provider.displayName), \(account.label)"]
        if let plan = card.plan { parts.append(plan) }
        if let hero = card.hero { parts.append("\(hero.percentLeft) percent \(hero.label)") }
        if let v = card.verdict { parts.append(v.title + ". " + v.primary) }
        if let m = card.sessionModule { parts.append("5-hour session: \(m.title). \(m.forecast)") }
        if let f = card.fault { parts.append(f.message) }
        return parts.joined(separator: ". ")
    }
}

/// The detailed 5-hour panel: cells, the session's graph with its trail, and the forecast.
struct SessionModuleView: View {
    var module: SessionModuleModel
    var chart: WidgetChart?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let tone = module.level >= .amber ? p.tone(module.level == .amber ? .tight : .veryTight) : p.tone(module.tone)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if module.level >= .amber { WarningGlyph(fill: tone.text, ink: p.cardSolid, size: 13) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title).font(.subheadline.weight(.semibold)).foregroundStyle(module.level >= .amber ? tone.text : p.ink)
                    Text(module.subtitle).font(.caption).foregroundStyle(p.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(module.countdown).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(module.level >= .amber ? tone.text : p.ink)
                    Caps(module.caption, size: 8)
                }
            }
            if let meter = module.meter {
                CellMeter(state: meter.state, cells: meter.cells, caret: meter.caret, height: 10, dim: meter.opacity < 1)
            }
            if let chart, module.glide != nil {
                GlideChartView(chart: chart, tone: tone).frame(height: 96)
            }
            Text(module.forecast).font(.footnote.weight(.medium))
                .foregroundStyle(module.outlook == .runsOut || module.outlook == .blocked ? tone.text : p.muted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(module.level >= .amber ? tone.text.opacity(0.10) : p.groupFill))
    }
}

/// The compact session row's warning banner (when Settings on the Mac picked the single row).
struct SessionBannerView: View {
    var banner: SessionBannerModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme), t = p.tone(banner.level >= .rose ? .veryTight : .tight)
        HStack(spacing: 10) {
            Ring(fraction: 1 - banner.used, tone: t, width: 3).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.subheadline.weight(.semibold)).foregroundStyle(t.text)
                Text(banner.subtitle).font(.caption).foregroundStyle(p.muted)
            }
            Spacer()
            Text(banner.countdown).font(.headline.monospacedDigit()).foregroundStyle(t.text)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.text.opacity(0.10)))
    }
}

struct FaultBanner: View {
    var model: FaultBannerModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.rose)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.message).font(.footnote.weight(.medium)).foregroundStyle(p.ink)
                if let detail = model.detail { Text(detail).font(.caption).foregroundStyle(p.muted) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.rose.opacity(0.10)))
    }
}

struct CalloutView: View {
    var callout: CalloutModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        let color: Color = switch callout.kind {
        case .capEmpty: p.rose
        case .capTight: p.amber
        case .earlyReset: p.azure
        }
        HStack(spacing: 8) {
            Image(systemName: callout.kind == .earlyReset ? "sparkles" : "exclamationmark.circle.fill").foregroundStyle(color)
            Text(callout.text).font(.footnote.weight(.medium)).foregroundStyle(p.ink)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.10)))
    }
}

struct DetailRow: View {
    var row: DetailRowModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette(scheme)
        HStack(spacing: 10) {
            Group {
                switch row.icon {
                case .ring(let used, let level):
                    Ring(fraction: 1 - used, tone: p.tone(level >= .amber ? .tight : .plenty), width: 2.5)
                case .hourglass(let highlight):
                    Hourglass(color: highlight ? p.tone(.plenty).text : p.muted, height: 13)
                case .coin(let provider):
                    MarkShape(provider: provider).fill(BrandColors.of(provider).base)
                }
            }
            .frame(width: 18, height: 18)
            Text(row.label).font(.footnote).foregroundStyle(p.muted)
            Spacer()
            Text(row.value).font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(row.highlight ? p.tone(.plenty).text : p.ink)
            if let suffix = row.suffix { Text(suffix).font(.caption).foregroundStyle(p.muted2) }
        }
    }
}
