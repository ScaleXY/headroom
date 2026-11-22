import AppKit
import HeadroomCore
import HeadroomKit
import HeadroomPresent
import HeadroomSync
import os

/// Diagnostics: counts and timings only (no paths, tokens or account data).
let diag = Logger(subsystem: "com.scalexy.headroom", category: "engine")

/// Persisted between launches (`state.plist`): history and last good readings. The ingestion
/// state (cursors, ledger) lives in `ingest.plist`, which the scan child reads and writes directly.
struct PersistedState: Codable, Sendable {
    var version = 2
    var history = HistoryStore()
    var lastGood: [String: LimitReading] = [:]
    var claudeRefreshLastRun: Date?
    var codexAccountKey: String?
    /// When each provider's account changed, for attributing synced activity. Optional, so state
    /// saved before sync existed still decodes (an added required field would wipe the history).
    var accountTimeline: AccountTimeline?
}

/// Owns every Core component and turns their results into presentation input. Main actor;
/// the Core actors do the work off the main thread.
@MainActor
final class AppModel {
    let settings: AppSettings
    private let notifier: Notifier
    private(set) var history = HistoryStore()
    private(set) var faults: [Provider: FaultMachine] = [:]
    private(set) var buckets = UsageBuckets()
    private(set) var serviceStatus: [Provider: ServiceStatus] = [:]
    private(set) var firstScanDone = false
    private(set) var scanProgress: String?
    var popoverOpen = false { didSet { if popoverOpen { popoverOpened() } } }

    /// Called on the main actor whenever anything visible changed.
    var onChange: (() -> Void)?

    private let store = PlistStore<PersistedState>.standard(named: "state.plist")
    private let ingestStore = PlistStore<IngestState>.standard(named: "ingest.plist")
    private var saver: DebouncedSaver?
    private var ingestor: LogIngestor
    /// `ingestor.persistRevision` last written to disk in full; nil when the files may be stale.
    private var savedIngestRevision: Int?
    /// The latest disk write, so writes land in the order they were asked for.
    private var lastWrite: Task<Bool, Never>?
    private var watcher: LogWatcher?
    private let resolver = CLIResolver()
    private var claude: ClaudeUsageClient!
    private var codex: CodexAppServerClient!
    private var refresher: ClaudeRefresher!
    private let statusClient = StatusClient()
    private var scheduler: AdaptiveScheduler
    private let timer = SchedulerTimer()
    private var minuteTimer: Timer?
    private let reachability = NWPathReachability()
    private var refreshObserver: RefreshObserver?
    private var inFlight: Set<Provider> = []
    private var codexAccountKey: String?
    private var pricing: PricingEngine
    private var pricingOverrideStamp: Date?
    private var lastSnapshotBody: Data?
    private var observers: [NSObjectProtocol] = []
    private let snapshotWriter = SnapshotWriter()
    private let widgets = WidgetPublisher()
    /// iPhone & Watch sync (Settings → iPhone & Watch).
    let publisher = CloudPublisher()
    /// Which account each provider was signed in with, and since when.
    private(set) var timeline = AccountTimeline()
    /// Agent runs being tracked, most pressing first (empty while task tracking is off).
    private(set) var taskRuns: [TaskRun] = []
    private var tasks: TaskTracker?
    /// The limits and spend runs are read against, rebuilt with the snapshot.
    private(set) var limitInputs = TaskLimitInputs()
    private var quietAfter: TimeInterval

    init(settings: AppSettings) {
        self.settings = settings
        quietAfter = settings.runQuietAfter
        notifier = Notifier(settings: settings)
        let persisted = PlistStore<PersistedState>.standard(named: "state.plist").load() ?? PersistedState()
        history = persisted.history
        codexAccountKey = persisted.codexAccountKey
        timeline = persisted.accountTimeline ?? AccountTimeline()
        for p in Provider.allCases {
            faults[p] = FaultMachine(provider: p, lastGood: persisted.lastGood[p.rawValue])
        }
        pricing = PricingEngine.standard()
        pricingOverrideStamp = Self.overrideStamp()
        let engine = pricing
        // Empty until the first scan; the scan child loads `ingest.plist` itself (see `fullScan`).
        ingestor = LogIngestor(pricer: Self.pricer(engine), state: nil)
        scheduler = AdaptiveScheduler(enabled: settings.enabledProviders, statusChecksEnabled: settings.statusChecks)

        let resolver = self.resolver
        refresher = ClaudeRefresher(lastRun: persisted.claudeRefreshLastRun) { await resolver.path(for: .claude) }
        claude = ClaudeUsageClient(refresher: refresher)
        codex = CodexAppServerClient { await resolver.path(for: .codex) }
        notifier.openRun = { [weak self] id in
            // The tracker's runs, else the feed on disk (tracking may have been turned off since).
            let run = self?.taskRuns.first { $0.id == id } ?? TasksFile.read(from: TasksFile.url())?.run(id)
            if let run { RunActions.openSession(run) }
        }
    }

    static func pricer(_ engine: PricingEngine) -> EventPricer {
        { event in
            let c = engine.price(event)
            return EventPrice(cost: ClassCost(input: c.input, cacheWrite: c.cacheWrite, cacheRead: c.cacheRead, output: c.output), priced: c.priced)
        }
    }

    private static func overrideStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: PriceTable.defaultOverrideURL.path))?[.modificationDate] as? Date
    }

    // MARK: Lifecycle

    func start() {
        saver = DebouncedSaver(delay: .seconds(300)) { [weak self] in await self?.save() }
        Task { await applyCLIOverrides() }
        startObservers()
        reachability.start { [weak self] satisfied in
            Task { @MainActor in self?.pathChanged(satisfied) }
        }
        refreshObserver = RefreshObserver { [weak self] in
            Task { @MainActor in self?.refreshNow() }
        }
        Task { await firstScan() }
        // Read limits right away on launch.
        scheduler.refreshNow()
        tick()
        if settings.syncEnabled { Task { await publisher.start(model: self) } }
    }

    func applyCLIOverrides() async {
        await resolver.setOverride(settings.cliPath("claude"), for: .claude)
        await resolver.setOverride(settings.cliPath("codex"), for: .codex)
        await resolver.invalidate()
    }

    func settingsChanged() {
        scheduler.enabled = settings.enabledProviders
        scheduler.statusChecksEnabled = settings.statusChecks
        if !settings.statusChecks { serviceStatus = [:]; for p in Provider.allCases { faults[p]?.applyStatus(nil) } }
        Task {
            await applyCLIOverrides()
            // CLI-missing faults retry on settings changes.
            scheduler.refreshNow()
            tick()
        }
        if settings.syncEnabled, !publisher.isRunning, publisher.status == .off {
            Task { await publisher.start(model: self) }
        } else if !settings.syncEnabled, publisher.isRunning {
            publisher.stop()
        }
        if firstScanDone { updateTaskTracking() }
        if settings.runQuietAfter != quietAfter {
            quietAfter = settings.runQuietAfter
            tasks?.refresh()
        }
        changed()
    }

    /// Starts or stops the transcript observer and `tasks.json` writer to match the setting.
    private func updateTaskTracking() {
        if settings.taskTracking, tasks == nil {
            let t = TaskTracker(settings: settings, notifier: notifier) { [weak self] in self?.limitInputs ?? TaskLimitInputs() }
            t.onChange = { [weak self, weak t] in
                guard let self, let t else { return }
                self.taskRuns = t.runs
                self.onChange?()
                self.publisher.update()
            }
            tasks = t
            t.start()
        } else if !settings.taskTracking, let t = tasks {
            t.stop()
            tasks = nil
        }
    }

    private func firstScan() async {
        scanProgress = "Reading local logs…"
        changed()
        await fullScan()
        firstScanDone = true
        scanProgress = nil
        await absorbPassiveCodex()
        changed()
        await saver?.schedule()
        let standardRoots = LogRoots.standard()
        let roots = standardRoots.claude + standardRoots.codex
        watcher = LogWatcher(roots: roots, latency: 3) { [weak self] paths, rescan in
            Task { @MainActor in await self?.logsChanged(paths: paths, rescan: rescan) }
        }
        _ = watcher?.start()
        updateTaskTracking()
    }

    /// Runs a full scan in a child process when possible (see `ScanChild`), in-process otherwise.
    private func fullScan() async {
        let t0 = Date()
        defer { diag.notice("full scan \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s") }
        if firstScanDone { await saveIngest() } // hand the child our latest cursors
        if Bundle.main.bundleURL.pathExtension == "app", let scanned = await ScanChild.scan(stateURL: ingestStore.url) {
            ingestor = LogIngestor(pricer: Self.pricer(pricing), state: scanned)
            savedIngestRevision = nil
        } else {
            if !firstScanDone, let saved = ingestStore.load() {
                ingestor = LogIngestor(pricer: Self.pricer(pricing), state: saved)
                savedIngestRevision = nil
            }
            _ = await ingestor.scanAll()
            await saveIngest()
        }
        buckets = await ingestor.buckets()
        await mapLedger()
    }

    private var ledgerURL: URL { ingestStore.url.deletingLastPathComponent().appendingPathComponent("ledger.bin") }

    /// Keeps the ledger file-backed so its pages don't count toward the resident footprint.
    private func mapLedger() async {
        await ingestor.mapLedger(file: ledgerURL)
        Memory.relieve()
    }

    /// Writes `ingest.plist` and `ledger.bin`, unless both already hold this ingestor's state:
    /// they are about 12 MB, and most saves come from limit reads that touch neither.
    private func saveIngest() async {
        let current = ingestor
        if let saved = savedIngestRevision, await current.persistRevision == saved { return }
        let (state, revision, mapped) = await current.exportState(mappingLedgerTo: ledgerURL)
        let store = ingestStore
        let written = await write { (try? store.save(state)) != nil }
        Memory.relieve()
        if written, mapped, current === ingestor { savedIngestRevision = revision }
    }

    /// Runs a disk write off the main actor, after any earlier one, so an older state never
    /// lands over a newer one. Awaiting it means the file is on disk.
    private func write(_ body: @escaping @Sendable () -> Bool) async -> Bool {
        let previous = lastWrite
        let task = Task.detached(priority: .utility) { () -> Bool in
            _ = await previous?.value
            return body()
        }
        lastWrite = task
        return await task.value
    }

    private func logsChanged(paths: [String], rescan: Bool) async {
        if rescan { tasks?.rescan() } else { tasks?.transcriptsChanged(paths) }
        if rescan {
            diag.notice("watcher asked for a rescan (\(paths.count) paths)")
            await fullScan()
        } else {
            let report = await ingestor.ingest(paths: paths)
            diag.notice("ingest files=\(report.filesRead) bytes=\(report.bytesProcessed) events=\(report.eventsAdded) \(report.seconds, format: .fixed(precision: 3))s")
            guard report.eventsAdded > 0 else { return }
            buckets = await ingestor.buckets()
        }
        scheduler.logActivity(at: Date())
        await absorbPassiveCodex()
        // Signed-out faults retry on log activity.
        for p in Provider.allCases where faults[p]?.retryPolicy?.onLogActivity == true { scheduler.refreshNow([p]) }
        changed()
        await saver?.schedule()
        tick()
    }

    /// Fresh `rate_limits` from an `openai`-provider Codex session update the Codex reading without a spawn.
    private func absorbPassiveCodex() async {
        guard settings.enabledProviders.contains(.codex),
              let passive = await ingestor.passiveLimits(trustedOnly: true),
              let reading = passive.reading(accountKey: codexAccountKey) else { return }
        let current = faults[.codex]?.lastGood
        guard reading.fetchedAt > (current?.fetchedAt ?? .distantPast) else { return }
        var merged = reading
        // Keep the plan, credits and caps from the last full read for the same account.
        if let current, current.accountKey == reading.accountKey {
            merged.accountEmail = current.accountEmail
            merged.resetCredits = current.resetCredits
            merged.resetCreditsAvailable = current.resetCreditsAvailable
            if merged.plan == nil { merged.plan = current.plan }
            merged.windows += current.modelCaps
        }
        accept(merged, provider: .codex)
        scheduler.passiveCodexReading(at: reading.fetchedAt)
    }

    func save() async {
        let t0 = Date()
        defer { diag.notice("saved state \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s") }
        if firstScanDone { await saveIngest() }
        var state = PersistedState()
        state.history = history
        for p in Provider.allCases { if let g = faults[p]?.lastGood { state.lastGood[p.rawValue] = g } }
        state.claudeRefreshLastRun = await refresher.lastRunDate
        state.codexAccountKey = codexAccountKey
        state.accountTimeline = timeline
        let (store, final) = (self.store, state)
        _ = await write { (try? store.save(final)) != nil }
        Memory.relieve()
    }

    func flushOnQuit() async {
        await tasks?.flush()
        await publisher.quit()
        await save()
    }

    // MARK: Scheduling

    private func tick() {
        let now = Date()
        for action in scheduler.due(at: now) {
            switch action {
            case .readLimits(let p): read(p)
            case .checkStatus(let p): checkStatus(p)
            }
        }
        armTimer()
    }

    private func armTimer() {
        let now = Date()
        guard let next = scheduler.nextDeadline(at: now) else { timer.cancel(); return }
        let delay = max(next.timeIntervalSince(now), 1)
        timer.arm(at: now.addingTimeInterval(delay), leeway: scheduler.leeway(forDelay: delay), now: now) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
    }

    func refreshNow() {
        scheduler.refreshNow()
        if settings.statusChecks { for p in settings.enabledProviders { checkStatus(p) } }
        // `headroom --refresh` waits for a new generated_at: write once the fresh reads land
        // (or after 8 s, so the CLI never waits its full 10 s for nothing).
        pendingRefreshWrite = true
        tick()
        if inFlight.isEmpty { finishRefreshWrite() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finishRefreshWrite() }
    }

    private var pendingRefreshWrite = false

    private func finishRefreshWrite() {
        guard pendingRefreshWrite else { return }
        pendingRefreshWrite = false
        lastSnapshotBody = nil
        writeSnapshot()
    }

    private func popoverOpened() {
        scheduler.popoverOpened(at: Date())
        if Self.overrideStamp() != pricingOverrideStamp {
            pricingOverrideStamp = Self.overrideStamp()
            pricing = PricingEngine.standard()
            let engine = pricing
            Task {
                await ingestor.reprice(Self.pricer(engine))
                buckets = await ingestor.buckets()
                changed()
            }
        }
        tick()
    }

    private func read(_ p: Provider) {
        guard !inFlight.contains(p), settings.enabledProviders.contains(p) else { return }
        // Codex: a fresh passive reading from the logs skips the spawn.
        if p == .codex, scheduler.codexPassiveIsFresh(at: Date()) {
            scheduler.recordLimitRead(p, at: Date(), succeeded: true, retryAt: nil)
            return
        }
        inFlight.insert(p)
        let popover = popoverOpen
        Task {
            let t0 = Date()
            let outcome: ProviderReadOutcome = p == .claude ? await claude.read(popoverOpen: popover) : await codex.read()
            let faultText: String = outcome.fault.map { f in if case .failed(let r) = f { return "error: " + r }; return f.code } ?? "ok"
            diag.notice("read \(p.rawValue, privacy: .public) \(faultText, privacy: .public) \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
            inFlight.remove(p)
            let now = Date()
            var machine = faults[p] ?? FaultMachine(provider: p)
            machine.recordOutcome(outcome, at: now)
            faults[p] = machine
            if let reading = outcome.reading, outcome.fault == nil {
                if p == .codex { codexAccountKey = reading.accountKey }
                accept(reading, provider: p)
            } else if let reading = outcome.reading {
                history.record(reading, now: now) // text fallback still extends the glide
            }
            if outcome.fault != nil, settings.statusChecks { checkStatus(p) }
            scheduler.recordLimitRead(p, at: now, succeeded: outcome.fault == nil, retryAt: machine.nextRetryAt)
            changed()
            if inFlight.isEmpty { finishRefreshWrite() }
            await saver?.schedule()
            armTimer()
        }
    }

    private func accept(_ reading: LimitReading, provider p: Provider) {
        var machine = faults[p] ?? FaultMachine(provider: p)
        if reading.source == .passiveLog { machine.recordSuccess(reading) } else if machine.lastGood != reading { machine.recordSuccess(reading) }
        faults[p] = machine
        history.record(reading, now: reading.fetchedAt)
        updateTracker(p, reading: reading)
        let key = reading.accountKey ?? PayloadBuilder.deviceScopedKey(p, deviceID: publisher.deviceID)
        if timeline.record(p, accountKey: key, at: reading.fetchedAt) { timeline.prune(before: Date().addingTimeInterval(-90 * 86400)) }
    }

    private func updateTracker(_ p: Provider, reading: LimitReading) {
        guard let headline = reading.headline, headline.resetsAt != nil else { return }
        let key = HistoryStore.key(p, account: reading.accountKey)
        guard var acct = history.accounts[key] else { return }
        let samples = acct.windows[headline.id]?.samples ?? []
        let now = Date()
        let analysis = PacingEngine.analyze(window: headline, samples: samples, now: now)
        var tracker = acct.tracker ?? PacingTracker(policy: .standard)
        _ = tracker.update(analysis, now: now)
        acct.tracker = tracker
        history.accounts[key] = acct
    }

    private func checkStatus(_ p: Provider) {
        guard settings.statusChecks else { return }
        Task {
            let status = await statusClient.fetch(p)
            diag.notice("status \(p.rawValue, privacy: .public) \(status?.level.rawValue ?? -1)")
            scheduler.recordStatusCheck(p, at: Date())
            if let status { serviceStatus[p] = status }
            faults[p]?.applyStatus(status)
            changed()
            armTimer()
        }
    }

    private func pathChanged(_ satisfied: Bool) {
        guard satisfied else { return }
        let waiting = Set(Provider.allCases.filter { faults[$0]?.retryPolicy?.onPathSatisfied == true })
        scheduler.pathSatisfied(retrying: waiting)
        tick()
    }

    private func startObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.sleep(); self?.timer.cancel() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.wake(at: Date()); self?.tick() }
        })
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.screenLocked(); self?.armTimer() }
        })
        observers.append(dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.screenUnlocked(at: Date()); self?.tick() }
        })
    }

    // MARK: Change propagation

    private func changed() {
        onChange?()
        let limits = writeSnapshot()
        notify()
        armMinuteTimer()
        // Runs fold again when a window or a block moved; spend alone waits for the next fold.
        if limits { tasks?.limitsChanged() }
    }

    private func notify() {
        guard firstScanDone else { return }
        notifier.evaluate(paceInputs(), presenter: presenter(now: Date()))
    }

    /// While a countdown is visible (session warning, blocked) or the popover is open, redraw once a minute.
    private func armMinuteTimer() {
        let needs = popoverOpen || menuBarHasCountdown()
        if needs, minuteTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange?()
                    self.writeSnapshot()
                    self.notify()
                    if !(self.popoverOpen || self.menuBarHasCountdown()) { self.minuteTimer?.invalidate(); self.minuteTimer = nil }
                }
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            minuteTimer = t
        } else if !needs {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
    }

    private func menuBarHasCountdown() -> Bool {
        let p = presenter(now: Date())
        return paceInputs().compactMap { p.menuBar($0)?.model }.contains { $0.session != nil || $0.blockedCountdown != nil }
    }

    // MARK: Presentation input

    /// A presenter with the user's 5-hour threshold and display options.
    func presenter(now: Date) -> Presenter {
        Presenter(now: now, policy: settings.policy, options: settings.presentation)
    }

    func paceInput(_ p: Provider) -> PaceInput {
        let machine = faults[p]
        let reading = machine?.lastGood
        var input = PaceInput(provider: p, reading: reading)
        input.fault = machine?.fault
        if let reading {
            let acct = history.account(p, reading.accountKey)
            if let acct {
                input.samples = acct.windows.mapValues(\.samples)
                if let session = acct.session { input.samples[LimitWindow.sessionID()] = session.samples }
                // The session trail's last day, and every session in the week for the Limits lane.
                let since = min(Date().addingTimeInterval(-(Presenter.sessionTrailHours + 5) * 3600), reading.headline?.windowStart ?? .distantFuture)
                input.pastSessions = acct.finishedSessions(since: since, now: Date())
            }
            input.smoothedState = acct?.tracker?.shown
            if let early = acct?.earlyResetAt, let start = reading.headline?.windowStart, early >= start { input.earlyResetAt = early }
            if let start = reading.headline?.windowStart {
                input.weekCostMicros = buckets.totals(p, from: start, to: Date()).micros
            }
        } else if input.fault == nil, !firstScanDone || inFlight.contains(p) {
            input.fault = nil
        }
        input.planMonthlyOverride = settings.planPriceOverride(p)
        input.runSpend = runSpend(p)
        return input
    }

    func paceInputs() -> [PaceInput] {
        Provider.allCases.filter { settings.enabledProviders.contains($0) }.map(paceInput)
    }

    /// The soonest upcoming 5-hour session reset among the enabled providers.
    func nextSessionReset(now: Date = Date()) -> Date? {
        paceInputs().compactMap { $0.reading?.session?.resetsAt }.filter { $0 > now }.min()
    }

    var majorOutages: [Provider: String] {
        serviceStatus.compactMapValues { $0.level >= .majorOutage ? ($0.description ?? "Major outage") : nil }
    }

    /// Footer line: all good, or the outage.
    var footer: FooterModel {
        if let scan = scanProgress { return FooterModel(text: scan, status: .stale) }
        let outages = serviceStatus.filter { settings.enabledProviders.contains($0.key) && $0.value.isOutage }
        if let (p, s) = outages.sorted(by: { $0.key < $1.key }).first {
            return FooterModel(text: s.description ?? "\(p.displayName) outage", status: .error)
        }
        return FooterModel(text: "All systems normal", status: .fresh)
    }

    func aggregates() -> [HourAggregate] {
        buckets.allSlots.map { s in
            HourAggregate(provider: s.key.provider, hour: Date(timeIntervalSince1970: Double(s.key.slot) * Double(UsageBuckets.slotSeconds)),
                          model: s.model, project: s.project.isEmpty ? nil : s.project, tokens: s.totals.tokens,
                          micros: s.totals.micros, priced: s.totals.unpricedTokens == 0,
                          classMicros: ClassMicros(input: s.totals.cost.input, cacheWrite: s.totals.cost.cacheWrite,
                                                    cacheRead: s.totals.cost.cacheRead, output: s.totals.cost.output))
        }
    }

    var pricingEngine: PricingEngine { pricing }

    // MARK: Snapshot

    /// Writes `snapshot.json` when it changed and keeps `limitInputs` in step. Returns whether the
    /// limits runs are read against moved (a 5-hour window or a block).
    @discardableResult
    private func writeSnapshot() -> Bool {
        widgets.update(WidgetFeedBuilder(now: Date()).build(model: self))
        publisher.update()
        let snapshot = SnapshotBuilder(now: Date()).build(model: self)
        let old = limitInputs
        limitInputs = TaskLimitInputs(providers: snapshot.providers, spend: providerSpend(snapshot.providers, now: snapshot.generatedAt))
        let moved = old.providers.map(LimitKey.init) != limitInputs.providers.map(LimitKey.init)
        var body = snapshot
        body.generatedAt = .distantPast
        let encoded = try? SnapshotFile.encoder().encode(body)
        if let encoded, encoded == lastSnapshotBody { return moved }
        lastSnapshotBody = encoded
        _ = try? snapshotWriter.write(snapshot)
        return moved
    }

    /// The parts of a provider's snapshot a run's outlook depends on.
    private struct LimitKey: Equatable {
        var id: Provider
        var session: SessionSnapshot?
        var blocked: BlockedSnapshot?
        init(_ s: ProviderSnapshot) { id = s.id; session = s.session; blocked = s.blocked }
    }

    /// What each provider is spending on this Mac: new tokens an hour over the last 45 to 60
    /// minutes (whole quarter-hour slots), and new tokens since its 5-hour window began.
    private func providerSpend(_ providers: [ProviderSnapshot], now: Date) -> [Provider: ProviderSpend] {
        let slot = TimeInterval(UsageBuckets.slotSeconds)
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / slot).rounded(.down) * slot - 3 * slot)
        let end = now.addingTimeInterval(slot) // through the slot in progress
        let hours = max(now.timeIntervalSince(start), 1800) / 3600
        var out: [Provider: ProviderSpend] = [:]
        for s in providers {
            let recent = buckets.totals(s.id, from: start, to: end).tokens.fresh
            let window = s.session?.resetsAt.flatMap { reset in
                reset > now ? buckets.totals(s.id, from: reset.addingTimeInterval(-5 * 3600), to: end).tokens.fresh : nil
            }
            out[s.id] = ProviderSpend(tokensPerHour: Double(recent) / hours, windowTokens: window)
        }
        return out
    }

    /// Each live run's share of what `p` is spending right now, for Pace's "What's spending it".
    func runSpend(_ p: Provider) -> [RunSpend] {
        taskRuns.compactMap { r in
            guard !r.hidden, r.state == .running || r.state == .waiting, let o = r.limitOutlook, o.provider == p,
                  let share = o.share, share > 0 else { return nil }
            return RunSpend(title: r.agentTitle ?? r.project ?? "Agent run", share: share)
        }
    }
}
