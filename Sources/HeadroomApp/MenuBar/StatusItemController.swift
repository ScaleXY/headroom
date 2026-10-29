import AppKit
import HeadroomKit

/// The single status item. Redraws only when its render key changes.
@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let popover: PopoverController
    private let caffeinate: Caffeinate
    var openSettings: (() -> Void)?
    var openWelcome: (() -> Void)?
    private var lastKey: [MenuBarProviderModel]?
    private var lastAppearanceDark: Bool?
    private var lastScale: CGFloat = 0
    private var appearanceObservation: NSKeyValueObservation?

    init(model: AppModel, popover: PopoverController, caffeinate: Caffeinate) {
        self.model = model
        self.popover = popover
        self.caffeinate = caffeinate
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
        guard force || items != lastKey || dark != lastAppearanceDark || scale != lastScale else { return }
        lastKey = items
        lastAppearanceDark = dark
        lastScale = scale
        let size = NSSize(width: StatusItemRenderer.width(items), height: StatusItemRenderer.height)
        // Touch the item only when something actually changed, and keep its width stable:
        // every relayout makes AppKit re-render the status button.
        if abs(item.length - (size.width + 8)) > 0.5 { item.length = size.width + 8 }
        // A finished CPU-rendered bitmap; AppKit only composites it.
        if let cg = StatusItemRenderer.renderBitmap(items, size: size, dark: dark, scale: scale) {
            let image = NSImage(cgImage: cg, size: size)
            image.isTemplate = false
            button.image = image
        }
        let spoken = items.map(\.spoken).joined(separator: " ")
        let label = spoken.isEmpty ? "Headroom" : spoken
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        let tip: String? = items.isEmpty ? "Headroom" : nil
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
        menu.addItem(withTitle: "Open Headroom", action: #selector(openPopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(keepAwakeItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Welcome Tour…", action: #selector(welcome), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Headroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

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

    @objc private func openPopover() { if let b = item.button { popover.show(relativeTo: b) } }
    @objc private func refresh() { model.refreshNow() }
    @objc private func settings() { openSettings?() }
    @objc private func welcome() { openWelcome?() }
}
