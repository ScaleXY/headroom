import AppKit
import HeadroomCore
import HeadroomKit
import HeadroomPresent

/// `HeadroomApp --render <scenario|all> --out <dir> [--light|--dark]`: draws surfaces offscreen
/// to PNG at 2×, for the visual pass against the mockups. Never touches live data.
@MainActor
enum RenderCommand {
    static func run(_ args: [String]) -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        // Pinned so the images look the same on every machine (README screenshots).
        Display.locale = Locale(identifier: "en_US")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Display.locale
        Display.calendar = cal
        let name = value("--render") ?? "all"
        let outDir = URL(fileURLWithPath: value("--out") ?? FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let themes: [Theme] = args.contains("--light") ? [.light] : args.contains("--dark") ? [.dark] : [.dark, .light]
        let now = Demo.now
        var written = 0
        for theme in themes {
            for s in Demo.paceScenarios(now: now) where name == "all" || name == s.name || name == "pace" {
                if let rep = PopoverPage.renderPace(s.inputs, theme: theme, now: now) {
                    write(rep, to: outDir.appendingPathComponent("pace-\(s.name)-\(theme.isDark ? "dark" : "light").png")); written += 1
                }
            }
        }
        // MARK: Limits chart fixtures on their own (`--render limits`); `all` and `pace` already include them.
        if name == "limits" {
            for theme in themes {
                for s in Demo.limitsScenarios(now: now) {
                    if let rep = PopoverPage.renderPace(s.inputs, theme: theme, now: now) {
                        write(rep, to: outDir.appendingPathComponent("pace-\(s.name)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
                // Settings → Meter off: the reservoir keeps its number and renewal, without the level.
                if let s = Demo.reservoirScenarios(now: now).first(where: { $0.name == "limits-ontrack" }),
                   let rep = PopoverPage.renderPace(s.inputs, theme: theme, now: now, configure: { $0.showsMeter = false }) {
                    write(rep, to: outDir.appendingPathComponent("pace-limits-nolevel-\(theme.isDark ? "dark" : "light").png")); written += 1
                }
            }
        }
        if name == "all" || name == "activity" {
            written += PopoverPage.writeActivityFixtures(themes: themes, to: outDir)
        }
        if name == "all" || name == "statusitem" {
            // The status item alone on a transparent background (3×), for marketing images.
            let presenter = Presenter(now: now)
            let items = presenter.menuBarItems([Demo.claudeMockup(now: now), Demo.codexMockup(now: now)], mode: .both, enabled: [.claude, .codex])
            let size = NSSize(width: StatusItemRenderer.width(items), height: StatusItemRenderer.height)
            for dark in [true, false] {
                if let cg = StatusItemRenderer.renderBitmap(items, size: size, dark: dark, scale: 3) {
                    write(NSBitmapImageRep(cgImage: cg), to: outDir.appendingPathComponent("statusitem-\(dark ? "dark" : "light").png")); written += 1
                }
                // With the Fan Control readout.
                let fan = FanReadout(temperature: 58, rpm: 3400)
                let fanSize = NSSize(width: StatusItemRenderer.width(items, fan: fan), height: StatusItemRenderer.height)
                if let cg = StatusItemRenderer.renderBitmap(items, fan: fan, size: fanSize, dark: dark, scale: 3) {
                    write(NSBitmapImageRep(cgImage: cg), to: outDir.appendingPathComponent("statusitem-fan-\(dark ? "dark" : "light").png")); written += 1
                }
            }
        }
        if name == "all" || name == "menubar-options" {
            for dark in [true, false] {
                for (option, options, mode) in PopoverPage.menuBarOptionRows {
                    let items = Demo.menuBarItems(options: options, mode: mode)
                    let size = NSSize(width: StatusItemRenderer.width(items), height: StatusItemRenderer.height)
                    if let cg = StatusItemRenderer.renderBitmap(items, size: size, dark: dark, scale: 3) {
                        write(NSBitmapImageRep(cgImage: cg), to: outDir.appendingPathComponent("statusitem-\(option)-\(dark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "menubar" {
            if let rep = PopoverPage.renderMenuBars(now: now) { write(rep, to: outDir.appendingPathComponent("menubar.png")); written += 1 }
        }
        if name == "all" || name == "share" {
            let shares = PopoverPage.demoShares()
            if let rep = ShareCardRenderer.card(shares[0]) { write(rep, to: outDir.appendingPathComponent("share-card-claude.png")); written += 1 }
            if let rep = ShareCardRenderer.card(shares[1]) { write(rep, to: outDir.appendingPathComponent("share-card-codex.png")); written += 1 }
            if let rep = ShareCardRenderer.snapshot(shares) { write(rep, to: outDir.appendingPathComponent("share-snapshot.png")); written += 1 }
            try? ShareBuilder.text(shares).write(to: outDir.appendingPathComponent("share-text.txt"), atomically: true, encoding: .utf8)
        }
        if name == "all" || name == "session" {
            for theme in themes {
                for (state, used) in PopoverPage.sessionStates {
                    if let rep = PopoverPage.renderSessionCard(used: used, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("session-\(state)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "onboarding" {
            for theme in themes {
                for step in 0..<OnboardingView.steps.count {
                    if let rep = PopoverPage.renderOnboarding(step: step, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("onboarding-\(step + 1)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "settings" {
            for theme in themes {
                for section in SettingsView.Section.allCases {
                    if let rep = PopoverPage.renderSettings(section: section, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("settings-\(section.rawValue + 1)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        if name == "all" || name == "runs" {
            for theme in themes {
                let suffix = theme.isDark ? "dark" : "light"
                for s in Demo.runScenarios(now: now) {
                    // The list, in each style for the busy fixtures.
                    let styles: [RunsListStyle] = ["mixed", "mixed-all"].contains(s.name) ? RunsListStyle.allCases : [.ledger]
                    for style in styles {
                        let tag = style == .ledger ? "" : "-\(style == .twoLine ? "twoline" : "fill")"
                        if let rep = PopoverPage.renderRuns(s, theme: theme, now: now, list: style) {
                            write(rep, to: outDir.appendingPathComponent("runs-\(s.name)\(tag)-\(suffix).png")); written += 1
                        }
                    }
                    if s.name == "mixed", let rep = PopoverPage.renderRuns(s, theme: theme, now: now, list: .twoLine, showFinished: true) {
                        write(rep, to: outDir.appendingPathComponent("runs-mixed-twoline-open-\(suffix).png")); written += 1
                    }
                    // Each run's own page, in each style (Lanes only while live).
                    for (i, r) in s.runs.filter({ !$0.hidden }).enumerated() {
                        for style in RunPageStyle.allCases where style == .briefing || !RunsPresenter.isFinished(r) {
                            if let rep = PopoverPage.renderRuns(s, theme: theme, now: now, run: r.id, pageStyle: style) {
                                write(rep, to: outDir.appendingPathComponent("runpage-\(s.name)-\(i + 1)-\(style == .briefing ? "briefing" : "lanes")-\(suffix).png"))
                                written += 1
                            }
                        }
                    }
                    // And the pages of the runs its other Macs synced.
                    for (i, d) in s.remote.enumerated() {
                        if let rep = PopoverPage.renderRuns(s, theme: theme, now: now, run: d.id) {
                            write(rep, to: outDir.appendingPathComponent("runpage-\(s.name)-synced-\(i + 1)-briefing-\(suffix).png")); written += 1
                        }
                    }
                }
                if let rep = PopoverPage.renderRecentRuns(theme: theme, now: now) {
                    write(rep, to: outDir.appendingPathComponent("runs-recent-\(suffix).png")); written += 1
                }
                if let rep = PopoverPage.renderSettings(section: .runs, theme: theme) {
                    write(rep, to: outDir.appendingPathComponent("settings-runs-\(suffix).png")); written += 1
                }
                // Runs › Layout in two combinations of styles: the preview follows the picks.
                for (list, page) in [(RunsListStyle.ledger, RunPageStyle.briefing), (.fill, .lanes), (.twoLine, .briefing)] {
                    let name = "settings-runs-layout-\(list.title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(page.title.lowercased())-\(suffix).png"
                    if let rep = PopoverPage.renderSettings(section: .runs, theme: theme, runsPage: .layout, configure: { $0.runsListStyle = list; $0.runPageStyle = page }) {
                        write(rep, to: outDir.appendingPathComponent(name)); written += 1
                    }
                }
                if let rep = PopoverPage.renderSettings(section: .runs, theme: theme, configure: { $0.taskTracking = false }) {
                    write(rep, to: outDir.appendingPathComponent("settings-runs-off-\(suffix).png")); written += 1
                }
                if let rep = PopoverPage.renderSettings(section: .menuBar, theme: theme) {
                    write(rep, to: outDir.appendingPathComponent("settings-menubar-runs-\(suffix).png")); written += 1
                }
                // iPhone & Watch with "Include task names" on.
                if let rep = PopoverPage.renderSettings(section: .sync, theme: theme, configure: { $0.syncEnabled = true; $0.syncTaskNames = true }) {
                    write(rep, to: outDir.appendingPathComponent("settings-sync-names-\(suffix).png")); written += 1
                }
            }
            // The menu bar with the run indicator (3×, transparent), and on wallpapers.
            let presenter = Presenter(now: now)
            let items = presenter.menuBarItems([Demo.claudeMockup(now: now), Demo.codexMockup(now: now)], mode: .both, enabled: [.claude, .codex])
            let rp = RunsPresenter(now: now)
            let indicators: [(String, RunsMenuBarModel?)] = Demo.menuBarRunSets(now: now).map { ("runs-" + $0.0, rp.menuBar($0.1)) }
            for dark in [true, false] {
                for (label, runs) in indicators {
                    guard let runs else { continue }
                    let size = NSSize(width: StatusItemRenderer.width(items, runs: runs), height: StatusItemRenderer.height)
                    if let cg = StatusItemRenderer.renderBitmap(items, runs: runs, size: size, dark: dark, scale: 3) {
                        write(NSBitmapImageRep(cgImage: cg), to: outDir.appendingPathComponent("statusitem-\(label)-\(dark ? "dark" : "light").png")); written += 1
                    }
                }
            }
            if let rep = PopoverPage.renderRunMenuBars(now: now) { write(rep, to: outDir.appendingPathComponent("menubar-runs.png")); written += 1 }
        }
        if name == "all" || name == "widget-feed" {
            // The widgets' feed built from the mockup fixtures: `HeadroomWidgetPreview <dir> --feed <file>` draws it.
            let feed = WidgetFeedBuilder(now: now).build([Demo.claudeMockup(now: now), Demo.codexMockup(now: now)],
                                                         presenter: Presenter(now: now, locale: Locale(identifier: "en_US")), buckets: UsageBuckets())
            if let data = try? SnapshotFile.encoder(pretty: true).encode(feed) {
                try? data.write(to: outDir.appendingPathComponent("widgets-demo.json")); written += 1
            }
        }
        if name == "all" || name == "updates" {
            for theme in themes {
                for (label, state) in PopoverPage.updateStates {
                    if let rep = PopoverPage.renderUpdateBanner(state, theme: theme) {
                        write(rep, to: outDir.appendingPathComponent("update-\(label)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                    if let rep = PopoverPage.renderSettings(section: .updates, theme: theme, update: state) {
                        write(rep, to: outDir.appendingPathComponent("settings-updates-\(label)-\(theme.isDark ? "dark" : "light").png")); written += 1
                    }
                }
            }
        }
        print("rendered \(written) image(s) to \(outDir.path)")
        return 0
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) {
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}

/// Composes whole popover pages offscreen (same drawing code as the live popover).
@MainActor
enum PopoverPage {
    static func renderPace(_ inputs: [PaceInput], theme: Theme, now: Date, configure: (inout PaceCardModel) -> Void = { _ in }) -> NSBitmapImageRep? {
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let cards = inputs.map { input -> PaceCardModel in
            var card = presenter.paceCard(input)
            configure(&card)
            return card
        }
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        var h = pad + PopoverChrome.headerHeight
        for (i, c) in cards.enumerated() { h += (i > 0 ? 10 : 0) + PaceCardRenderer.draw(c, origin: .zero, width: cw, theme: theme, ctx: nil) }
        h += PopoverChrome.footerHeight + pad
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            PopoverChrome.drawWindow(CGRect(x: 0, y: 0, width: w, height: h), theme: theme, ctx: ctx)
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, selected: 0, theme: theme, ctx: ctx, out: nil)
            var y = pad + PopoverChrome.headerHeight
            for (i, c) in cards.enumerated() {
                if i > 0 { y += 10 }
                y += PaceCardRenderer.draw(c, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            PopoverChrome.drawFooter(FooterModel(text: "All systems normal", status: .fresh), x: pad, y: y, width: cw, theme: theme, ctx: ctx, out: nil)
        }
    }

    /// The Runs tab of the popover for one fixture: the list in `list`'s style, or, with `run`, that
    /// run's own page in `pageStyle`.
    static func renderRuns(_ s: Demo.RunScenario, theme: Theme, now: Date, list: RunsListStyle = .ledger, showFinished: Bool = false,
                           run: String? = nil, pageStyle: RunPageStyle = .briefing) -> NSBitmapImageRep? {
        let page = RunsPresenter(now: now, calendar: Display.calendar, locale: Display.locale, pricing: demoPricing)
            .page(s.runs, remote: s.remote, expanded: s.expanded, opened: s.opened, allRecent: s.allRecent)
        let card = run.flatMap { id in (page.live + page.recent).first { $0.id == id } }
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        // A run's page keeps its way back in a row above it, as the popover does.
        let top = pad + PopoverChrome.headerHeight + (card == nil ? 0 : 36)
        func content(_ ctx: CGContext?, _ y: CGFloat) -> CGFloat {
            if let card {
                return RunPageRenderer.draw(card, style: pageStyle, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            return RunListRenderer.drawPage(page, style: list, showFinished: showFinished, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
        }
        let h = top + content(nil, 0) + 2 + PopoverChrome.footerHeight + pad
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            PopoverChrome.drawWindow(CGRect(x: 0, y: 0, width: w, height: h), theme: theme, ctx: ctx)
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, tabs: ["Limits", "Activity", "Runs"], selected: 2, theme: theme, ctx: ctx, out: nil)
            if let card {
                let position = page.live.firstIndex { $0.id == card.id }.map { "\($0 + 1) of \(page.live.count) live" } ?? "finished"
                PopoverRootView.drawRunCrumb(position: position, x: pad, y: pad + PopoverChrome.headerHeight, width: cw, theme: theme, ctx: ctx, out: nil)
            }
            let y = top + content(ctx, top) + 2
            PopoverChrome.drawFooter(FooterModel(text: "All systems normal", status: .fresh), x: pad, y: y, width: cw, theme: theme, ctx: ctx, out: nil)
        }
    }

    /// The bundled rates only: renders never read the user's price override.
    static var demoPricing: PricingEngine? { (try? PriceTable.bundled()).map(PricingEngine.init(table:)) }

    /// Activity's "Recent runs" section on its own, from the demo receipts.
    static func renderRecentRuns(theme: Theme, now: Date) -> NSBitmapImageRep? {
        guard let m = RecentRunsPresenter(now: now, pricing: demoPricing).model(Demo.recentRunRecords(now: now)) else { return nil }
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        let h = pad + RecentRunsRenderer.sectionHeaderHeight + RecentRunsRenderer.draw(m, origin: .zero, width: cw, theme: theme, ctx: nil) + pad
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            PopoverChrome.drawWindow(CGRect(x: 0, y: 0, width: w, height: h), theme: theme, ctx: ctx)
            RecentRunsRenderer.drawSectionHeader(m, x: pad, y: pad, width: cw, theme: theme, ctx: ctx)
            RecentRunsRenderer.draw(m, origin: CGPoint(x: pad, y: pad + RecentRunsRenderer.sectionHeaderHeight), width: cw, theme: theme, ctx: ctx)
        }
    }

    /// The menu bar with the run indicator on dark, light and busy wallpapers.
    static func renderRunMenuBars(now: Date) -> NSBitmapImageRep? {
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let items = presenter.menuBarItems([Demo.claudeMockup(now: now), Demo.codexMockup(now: now)], mode: .both, enabled: [.claude, .codex])
        let rp = RunsPresenter(now: now)
        let rows = Demo.menuBarRunSets(now: now).compactMap { rp.menuBar($0.1) }
        let w: CGFloat = 340, stripH: CGFloat = 28
        let backgrounds = ["dark", "light", "busy"]
        let h = CGFloat(rows.count * backgrounds.count) * (stripH + 6) + 6
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), rgb(0x808080))
            var y: CGFloat = 6
            for bg in backgrounds {
                for runs in rows {
                    let r = CGRect(x: 6, y: y, width: w - 12, height: stripH)
                    let dark = bg != "light"
                    switch bg {
                    case "dark": ctx.fillLinear(rounded(r, 6), [rgb(0x1A2150), rgb(0x3B2A5C), rgb(0x0F2F45)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    case "light": ctx.fillLinear(rounded(r, 6), [rgb(0xD6E4F7), rgb(0xF4E2EC), rgb(0xD8EEE7)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    default: ctx.fillLinear(rounded(r, 6), [rgb(0xE07A2F), rgb(0x2C7A4B), rgb(0xC9D84A), rgb(0x3A3FB0)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    }
                    ctx.fill(rounded(r, 6), dark ? rgb(0x080810, 0.3) : white(0.45))
                    let iw = StatusItemRenderer.width(items, runs: runs)
                    let x = r.maxX - 12 - iw
                    StatusItemRenderer.draw(items, in: CGRect(x: x, y: r.midY - 11, width: iw, height: 22), dark: dark, ctx: ctx)
                    StatusItemRenderer.drawRuns(runs, x: x + StatusItemRenderer.metersWidth(items) + 10, mid: r.midY, dark: dark, ctx: ctx)
                    y += stripH + 6
                }
            }
        }
    }

    /// Runs a layout pass against a scratch context to learn its height.
    static func measureHeight(_ layout: @escaping (CGContext?) -> CGFloat) -> CGFloat {
        var height: CGFloat = 0
        _ = renderImage(size: CGSize(width: 4, height: 4), scale: 1) { ctx in height = layout(ctx) }
        return height
    }

    /// Menu bar strips on dark, light and busy wallpapers, for every override.
    static func renderMenuBars(now: Date) -> NSBitmapImageRep? {
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let rows: [(String, [PaceInput])] = [
            ("mockup", [Demo.claudeMockup(now: now), Demo.codexMockup(now: now)]),
            ("update available", [Demo.claudeMockup(now: now), Demo.codexMockup(now: now)]),
            ("on track + very tight", [Demo.state(.claude, used: 0.52, elapsedH: 84, now: now), Demo.state(.codex, used: 0.82, elapsedH: 72, now: now)]),
            ("rose session + blocked", [Demo.state(.claude, used: 0.46, elapsedH: 90, session: 0.94, now: now), Demo.state(.codex, used: 0.46, elapsedH: 90, session: 1, now: now)]),
            ("fault + weekly blocked", [Demo.state(.claude, used: 0.46, elapsedH: 90, fault: .offline, now: now), Demo.state(.codex, used: 1, elapsedH: 140, now: now)]),
        ]
        let w: CGFloat = 340, stripH: CGFloat = 28
        let backgrounds = ["dark", "light", "busy"]
        let h = CGFloat(rows.count * backgrounds.count) * (stripH + 6) + 6
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), rgb(0x808080))
            var y: CGFloat = 6
            for bg in backgrounds {
                for (label, inputs) in rows {
                    let r = CGRect(x: 6, y: y, width: w - 12, height: stripH)
                    let dark = bg != "light"
                    switch bg {
                    case "dark": ctx.fillLinear(rounded(r, 6), [rgb(0x1A2150), rgb(0x3B2A5C), rgb(0x0F2F45)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    case "light": ctx.fillLinear(rounded(r, 6), [rgb(0xD6E4F7), rgb(0xF4E2EC), rgb(0xD8EEE7)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    default:
                        ctx.fillLinear(rounded(r, 6), [rgb(0xE07A2F), rgb(0x2C7A4B), rgb(0xC9D84A), rgb(0x3A3FB0)], from: r.origin, to: CGPoint(x: r.maxX, y: r.maxY))
                    }
                    ctx.fill(rounded(r, 6), dark ? rgb(0x080810, 0.3) : white(0.45))
                    let items = presenter.menuBarItems(inputs, mode: .both, enabled: [.claude, .codex])
                    let iw = StatusItemRenderer.width(items)
                    StatusItemRenderer.draw(items, in: CGRect(x: r.maxX - 12 - iw, y: r.midY - 11, width: iw, height: 22), dark: dark,
                                            updateBadge: label == "update available", ctx: ctx)
                    y += stripH + 6
                }
            }
        }
    }

    /// One welcome step at window size, with the window's traffic lights, from scratch settings.
    static func renderOnboarding(step: Int, theme: Theme, configure: ((AppSettings) -> Void)? = nil) -> NSBitmapImageRep? {
        let suite = "com.scalexy.headroom.render.onboarding"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        // The welcome as a typical user sees it: both tools found, a timer always on, the warning at 75%.
        settings.alwaysShowSessionTimer = step >= 2
        configure?(settings)
        let view = OnboardingView(settings: settings) { p in .signedIn(plan: p == .claude ? "MAX 20×" : "PRO") }
        view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let size = OnboardingView.size
        return renderImage(size: size, appearance: view.appearance) { ctx in
            let shape = rounded(CGRect(origin: .zero, size: size), 12)
            ctx.addPath(shape); ctx.clip()
            view.render(step: step, ctx: ctx)
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: 20 + CGFloat(i) * 20, y: 18, width: 12, height: 12))
                ctx.fill(dot, rgb(UInt32(hex)))
                ctx.stroke(dot, black(0.12), width: 0.5)
            }
            ctx.innerStroke(shape, theme.isDark ? white(0.12) : black(0.1), width: 1)
        }
    }

    /// One Settings section at window size, from scratch settings.
    static let updateStates: [(String, AppUpdater.State)] = [
        ("uptodate", .upToDate), ("available", .available("0.2.0")), ("downloading", .downloading("0.2.0", progress: 0.42)),
        ("installing", .installing("0.2.0")), ("ready", .ready("0.2.0")), ("failed", .failed("Couldn't reach the update server.")),
    ]

    /// The popover banner on its own, at popover width.
    static func renderUpdateBanner(_ state: AppUpdater.State, theme: Theme) -> NSBitmapImageRep? {
        let w = PopoverChrome.width, pad = PopoverChrome.pad
        let h = UpdateBannerRenderer.height + pad * 2
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), theme.windowFill)
            UpdateBannerRenderer.draw(state, rect: CGRect(x: pad, y: pad, width: w - pad * 2, height: UpdateBannerRenderer.height), theme: theme, ctx: ctx, out: nil)
        }
    }

    static func renderSettings(section: SettingsView.Section, theme: Theme, update: AppUpdater.State = .upToDate,
                               runsPage: SettingsView.RunsPage = .connect, configure: ((AppSettings) -> Void)? = nil) -> NSBitmapImageRep? {
        let suite = "com.scalexy.headroom.render.settings"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.alwaysShowSessionTimer = true
        configure?(settings)
        let view = SettingsView(settings: settings, model: nil, updater: AppUpdater(settings: settings, preview: update))
        view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        view.runsPage = runsPage
        let size = SettingsView.size
        return renderImage(size: size, appearance: view.appearance) { ctx in
            let shape = rounded(CGRect(origin: .zero, size: size), 12)
            ctx.addPath(shape); ctx.clip()
            view.render(section: section, ctx: ctx)
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let dot = CGMutablePath(); dot.addEllipse(in: CGRect(x: 20 + CGFloat(i) * 20, y: 18, width: 12, height: 12))
                ctx.fill(dot, rgb(UInt32(hex)))
                ctx.stroke(dot, black(0.12), width: 0.5)
            }
            ctx.innerStroke(shape, theme.isDark ? white(0.12) : black(0.1), width: 1)
        }
    }

    static let sessionStates: [(String, Double)] = [("idle", 0), ("comfortable", 0.42), ("runsout", 0.6), ("amber", 0.84), ("rose", 0.94), ("blocked", 1)]

    /// A card cut down to its header and the detailed 5-hour panel.
    static func renderSessionCard(used: Double, theme: Theme) -> NSBitmapImageRep? {
        let now = Demo.now
        let presenter = Presenter(now: now, locale: Locale(identifier: "en_US"))
        let input = Demo.state(.claude, used: 0.46, elapsedH: 90, session: used, now: now)
        var card = presenter.paceCard(input)
        guard var module = card.sessionModule else { return nil }
        module.onTop = true
        card.sessionModule = module
        let m: CGFloat = 12, w: CGFloat = 360, pad: CGFloat = 14
        let mh = PaceCardRenderer.sessionModuleHeight(module, width: w - pad * 2)
        let h = 13 + 28 + 12 + mh + 14
        return renderImage(size: CGSize(width: w + m * 2, height: h + m * 2)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w + m * 2, height: h + m * 2), transform: nil), theme.windowFill)
            CardChrome.draw(CGRect(x: m, y: m, width: w, height: h), provider: .claude, theme: theme, ctx: ctx)
            PaceCardRenderer.drawHeader(card, x: m + pad, y: m + 13, w: w - pad * 2, theme: theme, ctx: ctx, out: nil)
            PaceCardRenderer.drawSessionModule(module, rect: CGRect(x: m + pad, y: m + 13 + 28 + 12, width: w - pad * 2, height: mh), theme: theme, ctx: ctx)
        }
    }

    /// The menu bar under each Settings choice, one strip per row, at 3×.
    static let menuBarOptionRows: [(String, PresentationOptions, MenuBarMode)] = [
        ("default", PresentationOptions(), .both),
        ("percent", PresentationOptions(showPercent: true), .both),
        ("session", PresentationOptions(meterFocus: .session, alwaysShowSessionTimer: true), .both),
        ("tighter", PresentationOptions(meterFocus: .tighter, showPercent: true), .both),
        ("urgent", PresentationOptions(alwaysShowSessionTimer: true), .mostUrgent),
    ]

    static func demoShares() -> [ShareModel] {
        let now = Demo.activityNow
        let pricing = (try? PriceTable.bundled()).map { PricingEngine(table: $0) }
        let ap = ActivityPresenter(now: now, locale: Locale(identifier: "en_US"), pricing: pricing)
        let aggregates = pricing.map { Demo.activityAggregates(now: now, pricing: $0) } ?? []
        let pp = Presenter(now: Demo.now, locale: Locale(identifier: "en_US"))
        let paces = [pp.paceCard(Demo.claudeMockup(now: Demo.now)), pp.paceCard(Demo.codexMockup(now: Demo.now))]
        return [Provider.claude, .codex].enumerated().map { i, p in
            let card = ap.card(p, aggregates: aggregates, range: .day, selection: 4..<8)
            return ShareBuilder.make(activity: card, pace: paces[i], mode: .all, includeCost: true, burnInSpan: i == 0 ? 0.01 : 0.06, durationText: "4 hours")
        }
    }
}

// MARK: - Activity tab fixtures (redesign §4 window size, §5 Activity)

/// The Activity tab drawn offscreen from the demo data with the popover's own renderers: whole
/// pages for each range and the cached-reads switch, a selection, one provider, and the popover at
/// its resting height with the scroll cue.
@MainActor
extension PopoverPage {
    struct ActivityFixture {
        var name: String
        var mode: ActivityMode = .all
        var range: ActivityRange = .day
        var selection: Range<Int>? = nil
        var providers: [Provider] = [.claude, .codex]
        var collecting = false
        /// The popover at its resting height (cut off, with the scroll cue) instead of the whole page.
        var resting = false
    }

    static let activityFixtures: [ActivityFixture] = [
        ActivityFixture(name: "activity-all-24h", selection: 4..<8),
        ActivityFixture(name: "activity-all-7d", range: .week),
        ActivityFixture(name: "activity-all-30d", range: .month),
        ActivityFixture(name: "activity-new-24h", mode: .newOnly),
        ActivityFixture(name: "activity-new-7d", mode: .newOnly, range: .week, selection: 30..<36),
        ActivityFixture(name: "activity-new-30d", mode: .newOnly, range: .month),
        ActivityFixture(name: "activity-claude-only-24h", providers: [.claude]),
        ActivityFixture(name: "activity-collecting", collecting: true),
        ActivityFixture(name: "popover-activity-resting", resting: true),
        ActivityFixture(name: "popover-activity-resting-new", mode: .newOnly, range: .week, resting: true),
    ]

    static func writeActivityFixtures(themes: [Theme], to dir: URL) -> Int {
        var written = 0
        for theme in themes {
            for f in activityFixtures {
                guard let rep = renderActivity(f, theme: theme) else { continue }
                RenderCommand.write(rep, to: dir.appendingPathComponent("\(f.name)-\(theme.isDark ? "dark" : "light").png")); written += 1
            }
            if let rep = renderPastWeeks(theme: theme) {
                RenderCommand.write(rep, to: dir.appendingPathComponent("pastweeks-\(theme.isDark ? "dark" : "light").png")); written += 1
            }
        }
        return written
    }

    /// Past weeks for the demo, with the 5-hour sessions count from the demo sessions.
    static func demoPastWeeks(_ providers: [Provider], collecting: Bool) -> [PastWeeksModel] {
        Demo.pastWeeks(collecting: collecting).filter { providers.contains($0.provider) }.map { m in
            guard !m.collecting, let hit = HistoryPresenter.sessionsHit(Demo.sessionHistory(m.provider, now: Demo.now), now: Demo.now) else { return m }
            var m = m
            m.sessionsHit = hit
            m.chips = [m.chips[0], hit.chip]
            return m
        }
    }

    /// The Activity tab's card stack from `y`: summary, provider cards, Past weeks. Returns its height.
    static func drawActivityStack(_ f: ActivityFixture, theme: Theme, ctx: CGContext?, y y0: CGFloat) -> CGFloat {
        let now = Demo.activityNow
        let presenter = ActivityPresenter(now: now, locale: Locale(identifier: "en_US"), pricing: demoPricing)
        let aggregates = demoPricing.map { Demo.activityAggregates(now: now, pricing: $0) } ?? []
        let cards = f.providers.map { presenter.card($0, aggregates: aggregates, range: f.range, selection: f.selection) }
        let summary = presenter.summary(cards, range: f.range, mode: f.mode)
        let weeks = demoPastWeeks(f.providers, collecting: f.collecting)
        let pad = PopoverChrome.pad, cw = PopoverChrome.width - pad * 2
        var y = y0
        y += SummaryCardRenderer.draw(summary, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx) + 10
        for (i, c) in cards.enumerated() {
            if i > 0 { y += 10 }
            y += ActivityCardRenderer.draw(c, mode: f.mode, breakdown: .model, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
        }
        y += 16
        if let ctx { PastWeeksRenderer.drawSectionHeader(x: pad, y: y, width: cw, theme: theme, ctx: ctx) }
        y += PastWeeksRenderer.sectionHeaderHeight
        for (i, wk) in weeks.enumerated() {
            if i > 0 { y += 10 }
            y += PastWeeksRenderer.draw(wk, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
        }
        if !f.collecting {
            if let ctx { PastWeeksRenderer.drawLegend(x: pad, y: y, width: cw, theme: theme, ctx: ctx) }
            y += PastWeeksRenderer.legendHeight
        }
        return y - y0 + 2
    }

    /// The Limits tab's natural height for the mockup accounts: what sets the resting height.
    static func limitsNaturalHeight(theme: Theme) -> CGFloat {
        let presenter = Presenter(now: Demo.now, locale: Locale(identifier: "en_US"))
        let cards = [Demo.claudeMockup(now: Demo.now), Demo.codexMockup(now: Demo.now)].map { presenter.paceCard($0) }
        let pad = PopoverChrome.pad, cw = PopoverChrome.width - pad * 2
        let content = cards.enumerated().reduce(CGFloat(0)) { $0 + ($1.offset > 0 ? 10 : 0) + PaceCardRenderer.draw($1.element, origin: .zero, width: cw, theme: theme, ctx: nil) } + 2
        return pad + PopoverChrome.headerHeight + content + PopoverChrome.footerHeight + pad
    }

    static func renderActivity(_ f: ActivityFixture, theme: Theme) -> NSBitmapImageRep? {
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        let top = pad + PopoverChrome.headerHeight + 36, bottom = PopoverChrome.footerHeight + pad
        let content = measureHeight { ctx in drawActivityStack(f, theme: theme, ctx: ctx, y: 0) }
        // A 13-inch laptop's usable height, less the margin.
        let screenMax: Double = 900 - 24 - 16
        let resting = CGFloat(WindowSizing.resting(limitsNatural: Double(limitsNaturalHeight(theme: theme)), screenMax: screenMax))
        let h = f.resting ? resting : top + content + bottom
        let title = ActivityPresenter(now: Demo.activityNow, locale: Locale(identifier: "en_US")).rangeTitle(f.range)
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            PopoverChrome.drawWindow(CGRect(x: 0, y: 0, width: w, height: h), theme: theme, ctx: ctx)
            PopoverChrome.drawHeader(x: pad, y: pad, width: cw, selected: 1, theme: theme, ctx: ctx, out: nil)
            PopoverRootView.drawActivityControls(title: title, range: f.range, x: pad, y: pad + PopoverChrome.headerHeight, width: cw, theme: theme, ctx: ctx, out: nil)
            let area = CGRect(x: 0, y: top, width: w, height: h - top - bottom)
            ctx.withState {
                ctx.clip(to: area)
                _ = drawActivityStack(f, theme: theme, ctx: ctx, y: top)
                if f.resting, content > area.height + 4 {
                    // The cue, as CardsView draws it over the bottom of the card area.
                    let fade = CGRect(x: 0, y: area.maxY - 46, width: w, height: 46)
                    ctx.fillLinear(CGPath(rect: fade, transform: nil), [theme.windowFill.alpha(0), theme.windowFill],
                                   from: CGPoint(x: 0, y: fade.minY), to: CGPoint(x: 0, y: fade.maxY))
                    CardsView.drawScrollPill(centerX: w / 2, bottom: area.maxY - 8, theme: theme, ctx: ctx)
                }
            }
            PopoverChrome.drawFooter(FooterModel(text: "All systems normal", status: .fresh), x: pad, y: h - bottom, width: cw, theme: theme, ctx: ctx, out: nil)
        }
    }

    /// Past weeks on its own: the meter-cell columns and the sessions chips.
    static func renderPastWeeks(theme: Theme) -> NSBitmapImageRep? {
        let w = PopoverChrome.width, pad = PopoverChrome.pad, cw = w - pad * 2
        let weeks = demoPastWeeks([.claude, .codex], collecting: false)
        let cardsH = weeks.enumerated().reduce(CGFloat(0)) { $0 + ($1.offset > 0 ? 10 : 0) + PastWeeksRenderer.draw($1.element, origin: .zero, width: cw, theme: theme, ctx: nil) }
        let h = pad + PastWeeksRenderer.sectionHeaderHeight + cardsH + PastWeeksRenderer.legendHeight + pad
        return renderImage(size: CGSize(width: w, height: h)) { ctx in
            ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), theme.windowFill)
            var y = pad
            PastWeeksRenderer.drawSectionHeader(x: pad, y: y, width: cw, theme: theme, ctx: ctx)
            y += PastWeeksRenderer.sectionHeaderHeight
            for (i, m) in weeks.enumerated() {
                if i > 0 { y += 10 }
                y += PastWeeksRenderer.draw(m, origin: CGPoint(x: pad, y: y), width: cw, theme: theme, ctx: ctx)
            }
            PastWeeksRenderer.drawLegend(x: pad, y: y, width: cw, theme: theme, ctx: ctx)
        }
    }
}
