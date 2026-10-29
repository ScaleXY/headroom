import AppKit
import HeadroomKit
import HeadroomSMC

/// The single status item. Redraws only when its render key changes.
@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let popover: PopoverController
    private let caffeinate: Caffeinate
    private let fans: FanControl
    private let updater: AppUpdater
    var openSettings: (() -> Void)?
    var openWelcome: (() -> Void)?
    private var lastKey: [MenuBarProviderModel]?
    private var lastFan: FanReadout?
    private var lastBadge = false
    private var lastAppearanceDark: Bool?
    private var lastScale: CGFloat = 0
    private var appearanceObservation: NSKeyValueObservation?

    init(model: AppModel, popover: PopoverController, caffeinate: Caffeinate, fans: FanControl, updater: AppUpdater) {
        self.model = model
        self.popover = popover
        self.caffeinate = caffeinate
        self.fans = fans
        self.updater = updater
        super.init()
        item.autosaveName = "Headroom"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update(force: true) }
            }
        }
        update()
    }

    func update(now: Date = Date(), force: Bool = false) {
        let presenter = model.presenter(now: now)
        let items = presenter.menuBarItems(model.paceInputs(), mode: model.settings.menuBarMode,
                                           enabled: model.settings.enabledProviders, majorOutage: model.majorOutages)
        guard let button = item.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let fan = fans.readout
        // The same rule as the popover banner: putting it off there clears the dot too.
        let badge = UpdateBannerRenderer.shows(updater)
        guard force || items != lastKey || fan != lastFan || badge != lastBadge || dark != lastAppearanceDark || scale != lastScale else { return }
        lastKey = items
        lastFan = fan
        lastBadge = badge
        lastAppearanceDark = dark
        lastScale = scale
        let size = NSSize(width: StatusItemRenderer.width(items, fan: fan), height: StatusItemRenderer.height)
        // Touch the item only when something actually changed, and keep its width stable:
        // every relayout makes AppKit re-render the status button.
        if abs(item.length - (size.width + 8)) > 0.5 { item.length = size.width + 8 }
        // A finished CPU-rendered bitmap; AppKit only composites it.
        if let cg = StatusItemRenderer.renderBitmap(items, fan: fan, updateBadge: badge, size: size, dark: dark, scale: scale) {
            let image = NSImage(cgImage: cg, size: size)
            image.isTemplate = false
            button.image = image
        }
        let update = badge ? updater.state.version.map { "Headroom \($0) is available." } : nil
        let spoken = (items.map(\.spoken) + [fan?.spoken, update].compactMap(\.self)).joined(separator: " ")
        let label = spoken.isEmpty ? "Headroom" : spoken
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let tip: String? = update ?? (items.isEmpty ? "Headroom" : nil)
        if button.toolTip != tip { button.toolTip = tip }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            popover.toggle(relativeTo: sender)
        }
    }

    private func showMenu() {
        popover.close()
        let menu = NSMenu()
        if let item = updateItem() {
            menu.addItem(item)
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Open Headroom", action: #selector(openPopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(keepAwakeItem())
        if fans.hasFans { menu.addItem(fanControlItem()) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Welcome Tour…", action: #selector(welcome), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Headroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: Updates

    /// Leads the menu while an update is on offer: one click installs it, and the line
    /// under it says what's happening once it's under way.
    private func updateItem() -> NSMenuItem? {
        guard let version = updater.state.version else { return nil }
        let title: String = switch updater.state {
        case .downloading(_, let p): "Downloading Headroom \(version)" + (p.map { " · \(Int(($0 * 100).rounded()))%" } ?? "…")
        case .installing: "Installing Headroom \(version)…"
        default: "Update to Headroom \(version) and Restart"
        }
        let item = NSMenuItem(title: title, action: #selector(installUpdate), keyEquivalent: "")
        item.target = self
        switch updater.state {
        case .available, .ready: break
        default: item.action = nil
        }
        return item
    }

    @objc private func installUpdate() { updater.installAndRelaunch() }

    // MARK: Keep awake

    private func keepAwakeItem() -> NSMenuItem {
        let now = Date()
        let item = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        item.state = caffeinate.isOn ? .on : .off
        let sub = NSMenu()
        sub.autoenablesItems = false
        let toggle = NSMenuItem(title: caffeinate.isOn ? "Turn Off" : "Turn On · \(effective(model.settings.awakeDuration).title)", action: #selector(toggleAwake), keyEquivalent: "")
        toggle.target = self
        sub.addItem(toggle)
        if caffeinate.isOn {
            let status = caffeinate.until.map { "On until " + TimeFormat.shortDayTime($0, now: now, calendar: .current, locale: .current) }
                ?? "On until you turn it off"
            let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            line.isEnabled = false
            sub.addItem(line)
        }

        sub.addItem(.separator())
        sub.addItem(.sectionHeader(title: "Prevent"))
        let modes = caffeinate.isOn ? caffeinate.modes : model.settings.awakeModes
        for mode in AwakeMode.allCases {
            let m = NSMenuItem(title: mode.title, action: #selector(toggleAwakeMode(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = mode.rawValue
            m.state = modes.contains(mode) ? .on : .off
            m.toolTip = "\(mode.help) (caffeinate \(mode.flag))"
            // At least one assertion stays on.
            m.isEnabled = !(modes == [mode])
            sub.addItem(m)
        }

        sub.addItem(.separator())
        sub.addItem(.sectionHeader(title: "For"))
        let reset = model.nextSessionReset(now: now)
        for duration in AwakeDuration.allCases {
            var title = duration.title
            if duration == .sessionReset {
                guard let reset else { continue }
                title += " (\(TimeFormat.clock(reset, calendar: .current, locale: .current)))"
            }
            let d = NSMenuItem(title: title, action: #selector(pickAwakeDuration(_:)), keyEquivalent: "")
            d.target = self
            d.tag = duration.rawValue
            d.state = caffeinate.isOn && duration == model.settings.awakeDuration ? .on : .off
            sub.addItem(d)
        }
        item.submenu = sub
        return item
    }

    private func startAwake(_ duration: AwakeDuration, modes: Set<AwakeMode>) {
        let duration = effective(duration)
        model.settings.awakeDuration = duration
        model.settings.awakeModes = modes
        caffeinate.start(modes: modes, until: duration.end(from: Date(), sessionReset: model.nextSessionReset()))
    }

    /// With no 5-hour session running there's nothing to wait for, so say it runs until turned off.
    private func effective(_ duration: AwakeDuration) -> AwakeDuration {
        duration == .sessionReset && model.nextSessionReset() == nil ? .indefinitely : duration
    }

    @objc private func toggleAwake() {
        if caffeinate.isOn { caffeinate.stop() } else { startAwake(model.settings.awakeDuration, modes: model.settings.awakeModes) }
    }

    @objc private func pickAwakeDuration(_ sender: NSMenuItem) {
        guard let duration = AwakeDuration(rawValue: sender.tag) else { return }
        startAwake(duration, modes: model.settings.awakeModes)
    }

    @objc private func toggleAwakeMode(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap(AwakeMode.init(rawValue:)) else { return }
        var modes = model.settings.awakeModes
        if modes.contains(mode) { modes.remove(mode) } else { modes.insert(mode) }
        guard !modes.isEmpty else { return }
        model.settings.awakeModes = modes
        // Changing what's held while on restarts caffeinate with the same end time.
        if caffeinate.isOn { caffeinate.start(modes: modes, until: caffeinate.until) }
    }

    // MARK: Fan control

    private func fanControlItem() -> NSMenuItem {
        let settings = model.settings
        let item = NSMenuItem(title: "Fan Control", action: nil, keyEquivalent: "")
        item.state = fans.state == .on ? .on : fans.isOn ? .mixed : .off
        let sub = NSMenu()
        sub.autoenablesItems = false
        let toggle = NSMenuItem(title: fans.isOn ? "Turn Off" : "Turn On · \(settings.fanMinTemp)–\(settings.fanMaxTemp) °C",
                                action: #selector(toggleFans), keyEquivalent: "")
        toggle.target = self
        sub.addItem(toggle)

        switch fans.state {
        case .needsApproval:
            let allow = NSMenuItem(title: "Allow Headroom in Login Items…", action: #selector(openFanApproval), keyEquivalent: "")
            allow.target = self
            allow.toolTip = "Fan speeds need a small helper that runs as root. Turn on Headroom under Allow in the Background in System Settings → General → Login Items & Extensions."
            sub.addItem(allow)
        case .failed(let reason):
            sub.addItem(disabled(reason))
        case .off, .on:
            break
        }
        let reading = fans.reading()
        var parts: [String] = []
        if let t = reading.temperature { parts.append("\(settings.fanSensor.title) \(Int(t.rounded())) °C") }
        if !reading.speeds.isEmpty { parts.append(reading.speeds.map { Int($0.rounded()).formatted() }.joined(separator: ", ") + " rpm") }
        if !parts.isEmpty { sub.addItem(disabled(parts.joined(separator: " · "))) }

        sub.addItem(.separator())
        sub.addItem(fanSensorItem(settings.fanSensor))
        sub.addItem(fanTempItem("Min Temperature", value: settings.fanMinTemp, choices: AppSettings.fanMinTempChoices,
                                allowed: { $0 < settings.fanMaxTemp }, action: #selector(pickFanMin(_:)),
                                help: "Fans run at their lowest speed here and speed up as it gets hotter. Below it, macOS runs them."))
        sub.addItem(fanTempItem("Max Temperature", value: settings.fanMaxTemp, choices: AppSettings.fanMaxTempChoices,
                                allowed: { $0 > settings.fanMinTemp }, action: #selector(pickFanMax(_:)),
                                help: "Fans run at full speed from here."))
        item.submenu = sub
        return item
    }

    private func fanSensorItem(_ current: FanSensor) -> NSMenuItem {
        let item = NSMenuItem(title: "Sensor: \(current.title)", action: nil, keyEquivalent: "")
        item.toolTip = "The temperature the fan curve follows."
        let sub = NSMenu()
        sub.autoenablesItems = false
        for sensor in FanSensor.allCases {
            let s = NSMenuItem(title: sensor.title, action: #selector(pickFanSensor(_:)), keyEquivalent: "")
            s.target = self
            s.representedObject = sensor.rawValue
            s.state = sensor == current ? .on : .off
            s.toolTip = sensor.help
            sub.addItem(s)
        }
        item.submenu = sub
        return item
    }

    private func fanTempItem(_ title: String, value: Int, choices: [Int], allowed: (Int) -> Bool, action: Selector, help: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(value) °C", action: nil, keyEquivalent: "")
        item.toolTip = help
        let sub = NSMenu()
        sub.autoenablesItems = false
        for choice in choices {
            let c = NSMenuItem(title: "\(choice) °C", action: action, keyEquivalent: "")
            c.target = self
            c.tag = choice
            c.state = choice == value ? .on : .off
            c.isEnabled = allowed(choice)
            sub.addItem(c)
        }
        item.submenu = sub
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let line = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        line.isEnabled = false
        return line
    }

    @objc private func toggleFans() {
        if fans.isOn { fans.stop() } else { fans.start() }
    }

    @objc private func openFanApproval() { fans.openLoginItems() }

    @objc private func pickFanSensor(_ sender: NSMenuItem) {
        guard let sensor = (sender.representedObject as? String).flatMap(FanSensor.init(rawValue:)) else { return }
        model.settings.fanSensor = sensor
        if fans.isOn { fans.start(interactive: false) }
    }

    @objc private func pickFanMin(_ sender: NSMenuItem) {
        guard sender.tag < model.settings.fanMaxTemp else { return }
        model.settings.fanMinTemp = sender.tag
        if fans.isOn { fans.start(interactive: false) }
    }

    @objc private func pickFanMax(_ sender: NSMenuItem) {
        guard sender.tag > model.settings.fanMinTemp else { return }
        model.settings.fanMaxTemp = sender.tag
        if fans.isOn { fans.start(interactive: false) }
    }

    @objc private func openPopover() { if let b = item.button { popover.show(relativeTo: b) } }
    @objc private func refresh() { model.refreshNow() }
    @objc private func settings() { openSettings?() }
    @objc private func welcome() { openWelcome?() }
}
