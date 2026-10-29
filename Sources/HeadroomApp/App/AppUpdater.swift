import AppKit
import Sparkle

/// In-app updates through Sparkle 2. Sparkle reads the appcast, checks the EdDSA signature and that
/// the new build carries the same Developer ID, swaps the bundle and relaunches. Headroom draws every
/// step itself (Settings → Updates and the popover banner), so this is Sparkle's user driver: its
/// callbacks become one `State`, and the buttons answer the replies it hands over.
@MainActor
final class AppUpdater: NSObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// Found; nothing downloaded yet.
        case available(String)
        case downloading(String, progress: Double?)
        /// Extracting or handing over to the installer; the app quits and relaunches next.
        case installing(String)
        /// Downloaded in the background; it installs on quit, or now with a restart.
        case ready(String)
        case failed(String)

        var version: String? {
            switch self {
            case .available(let v), .downloading(let v, _), .installing(let v), .ready(let v): v
            default: nil
            }
        }

        /// An update the popover should offer.
        var offersUpdate: Bool {
            switch self {
            case .available, .downloading, .installing, .ready: true
            default: false
            }
        }
    }

    /// The full version, beta suffix included (CFBundleShortVersionString drops it).
    static var currentVersion: String? {
        let info = Bundle.main.infoDictionary
        return info?["HeadroomVersion"] as? String ?? info?["CFBundleShortVersionString"] as? String
    }

    private(set) var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// Sparkle asked to bring an update session forward (a check while one is open).
    var onFocus: (() -> Void)?
    /// The banner was put off for this version; Settings still shows it.
    private(set) var snoozed: String?

    private let settings: AppSettings
    private var updater: SPUUpdater?
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    private var installNow: (() -> Void)?
    private var cancelDownload: (() -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Drawn previews: a fixed state, Sparkle never started.
    init(settings: AppSettings, preview: State) {
        self.settings = settings
        super.init()
        state = preview
        previewing = true
        // A check a while ago, as a running copy shows it: the longest status the card has to fit.
        previewLastCheck = Date().addingTimeInterval(-5 * 3600)
    }

    /// Starts Sparkle when this is a release bundle with a feed and a signing key; `swift run`
    /// builds have neither and simply never update.
    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app", info["SUFeedURL"] != nil, info["SUPublicEDKey"] != nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            NSLog("Headroom: updates are off: \(error.localizedDescription)")
        }
    }

    private var previewing = false
    private var previewLastCheck: Date?
    var isAvailable: Bool { updater != nil || previewing }
    var lastCheck: Date? { updater?.lastUpdateCheckDate ?? previewLastCheck }

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set { updater?.automaticallyChecksForUpdates = newValue; onChange?() }
    }

    var automaticDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue; onChange?() }
    }

    var betaUpdates: Bool {
        get { settings.betaUpdates }
        set {
            settings.betaUpdates = newValue
            // A pending offer may be from the other channel; look again.
            if !newValue, foundReply != nil { foundReply?(.dismiss); foundReply = nil; state = .idle }
            onChange?()
        }
    }

    // MARK: Actions

    /// The Check Now button.
    func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        snoozed = nil
        updater.checkForUpdates()
    }

    /// Update & Restart: download if needed, install, relaunch.
    func installAndRelaunch() {
        if let installNow {
            self.installNow = nil
            if let v = state.version { state = .installing(v) }
            installNow()
        } else if let reply = foundReply {
            foundReply = nil
            if case .ready(let v) = state { state = .installing(v) } else if let v = state.version { state = .downloading(v, progress: nil) }
            reply(.install)
        }
    }

    /// Later: hide the banner until the next version (Settings keeps the button).
    func snooze() {
        snoozed = state.version
        onChange?()
    }

    /// Cancels a download in progress.
    func cancel() {
        cancelDownload?()
        cancelDownload = nil
    }
}

// MARK: - Sparkle's user driver

extension AppUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so Sparkle shouldn't ask; if it does, say yes quietly.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state s: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        // Information-only items can't install; there's nothing for a button to do.
        guard !appcastItem.isInformationOnlyUpdate else { reply(.dismiss); state = .upToDate; return }
        switch s.stage {
        case .installing:
            // Already on its way; a restart finishes it.
            installNow = { reply(.install) }
            state = .ready(version)
        case .downloaded:
            foundReply = reply
            state = .ready(version)
        default:
            foundReply = reply
            state = .available(version)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        state = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        state = .failed(Self.describe(error))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        expectedBytes = 0
        receivedBytes = 0
        if let v = state.version { state = .downloading(v, progress: nil) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        receivedBytes = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard let v = state.version, expectedBytes > 0 else { return }
        state = .downloading(v, progress: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        if let v = state.version { state = .installing(v) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Only reached after the user chose Update & Restart.
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if let v = state.version { state = .installing(v) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        state = .idle
        acknowledgement()
    }

    func showUpdateInFocus() {
        onFocus?()
    }

    func dismissUpdateInstallation() {
        foundReply = nil
        cancelDownload = nil
        switch state {
        // An offer still waiting on the user, a finished check or an error stays on screen.
        case .ready where installNow != nil, .upToDate, .failed: break
        default: state = .idle
        }
    }

    private static func describe(_ error: any Error) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain { return "Couldn't reach the update server." }
        return e.localizedDescription
    }
}

// MARK: - Sparkle's delegate

extension AppUpdater: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        settings.betaUpdates ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    /// A background download finished: it installs on quit, and the banner offers a restart now.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        state = .ready(item.displayVersionString)
        return true
    }
}
