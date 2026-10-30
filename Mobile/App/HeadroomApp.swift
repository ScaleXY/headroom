import BackgroundTasks
import HeadroomKit
import HeadroomMobileUI
import HeadroomSync
import SwiftUI
import UIKit

/// Headroom for iPhone and iPad. Everything shown comes from `HeadroomMobileUI`; this shell wires
/// the iCloud mirror, background wakes, widgets, the Live Activity, notifications and the Watch.
@main
struct HeadroomMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    private let services = AppServices.start()
    private let launchURL = UserDefaults.standard.string(forKey: "HeadroomOpen").flatMap(URL.init(string:))

    var body: some Scene {
        WindowGroup {
            HeadroomRootView(model: services.model, launchURL: launchURL)
        }
        .onChange(of: phase) { _, now in services.phaseChanged(now) }
        .backgroundTask(.appRefresh(AppServices.refreshTask)) { await services.backgroundRefresh() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CloudKit's silent pushes wake the app when a Mac writes; mirroring imports on its own.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // Give the import a moment to land, then rebuild widgets, the Live Activity and notifications.
        try? await Task.sleep(for: .seconds(6))
        await AppServices.shared?.model.reader.reload()
        return .newData
    }
}

/// The app's long-lived services, reached from intents and the app delegate.
@MainActor
final class AppServices {
    static let refreshTask = "com.scalexy.headroom.refresh"
    static private(set) var shared: AppServices?

    let model: MobileModel
    private let feedWriter = FeedWriter()
    private let liveActivities = LiveActivityController()
    private let relay = WatchRelay()
    private var foreground = true
    private var askedForNotifications = false

    private init(model: MobileModel) { self.model = model }

    static func start() -> AppServices {
        if let shared { return shared }
        // Signed builds carry the iCloud container and App Group; unsigned ones run on sample data.
        let cloudKit = Bundle.main.object(forInfoDictionaryKey: "HeadroomCloudKit") as? Bool ?? false
        var live: (any SyncReading)?
        if cloudKit, let container = try? SyncContainer.make(.appGroup(FeedFile.appGroup), cloudKit: true) {
            live = SyncStore(container: container)
        }
        let services = AppServices(model: MobileModel(live: live, cloudKit: cloudKit))
        services.model.setTracking = { [weak services] id, on in services?.setTracking(id, on) }
        services.model.reader.onRebuild = { [weak services] _ in services?.rebuilt() }
        services.model.start()
        shared = services
        return services
    }

    /// After every rebuild: widgets, the Live Activity, notifications and the Watch.
    private func rebuilt() {
        let feed = model.reader.feed
        feedWriter.write(feed, foreground: foreground)
        liveActivities.sync(feed, autoStart: foreground && model.prefs.autoTrackSessions)
        model.tracking = liveActivities.tracked
        relay.send(feed)
        let prefs = model.prefs
        // Ask for notifications once there's something real to be notified about, not at first launch.
        let ask = !askedForNotifications && foreground && !model.reader.isDemo && !model.reader.accounts.isEmpty
        if ask { askedForNotifications = true }
        Task {
            if ask { await ResetNotifier.requestPermission() }
            await ResetNotifier.schedule(feed, sessionBack: prefs.notifySessionBack, weekRenews: prefs.notifyWeekRenews)
        }
    }

    func phaseChanged(_ phase: ScenePhase) {
        foreground = phase == .active
        if phase == .active {
            Task { await model.reader.reload(); await model.refreshICloud() }
        } else if phase == .background {
            scheduleRefresh()
        }
    }

    /// A fallback wake for time-based changes (resets) when no sync arrives.
    func backgroundRefresh() async {
        scheduleRefresh()
        await model.reader.reload()
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func setTracking(_ id: String, _ on: Bool) {
        if on { liveActivities.start(id, feed: model.reader.feed) } else { liveActivities.stop(id) }
        model.tracking = liveActivities.tracked
    }

    /// From `TrackSessionIntent`: the given account, or the most urgent with a session running.
    static func toggleTracking(_ id: String?) async {
        guard let services = shared ?? Optional(start()) else { return }
        let feed = services.model.reader.feed
        let target = id ?? feed.focus(for: .session)?.key
        guard let target else { return }
        services.setTracking(target, !services.liveActivities.tracked.contains(target))
    }
}
