import HeadroomKit
import HeadroomSync
import HeadroomWatchUI
import SwiftUI
import WatchKit

/// Headroom for Apple Watch: its own iCloud mirror, plus the compact feed the iPhone relays for
/// the complications.
@main
struct HeadroomWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: WatchServices.shared.model)
        }
        .onChange(of: phase) { _, now in if now == .active { Task { await WatchServices.shared.model.reader.reload() } } }
    }
}

final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WKApplication.shared().registerForRemoteNotifications()
        _ = WatchServices.shared
    }

    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        try? await Task.sleep(for: .seconds(6))
        await WatchServices.shared.model.reader.reload()
        return .newData
    }
}

@MainActor
final class WatchServices {
    static let shared = WatchServices()
    let model: WatchModel
    private var receiver: PhoneRelayReceiver?

    private init() {
        // The build setting arrives as the string "YES"/"NO", which `as? Bool` never matches.
        let cloudKit = (Bundle.main.object(forInfoDictionaryKey: "HeadroomCloudKit") as? NSString)?.boolValue ?? false
        var live: (any SyncReading)?
        if cloudKit, let container = try? SyncContainer.make(.appGroup(FeedFile.appGroup), cloudKit: true) {
            live = SyncStore(container: container)
        }
        model = WatchModel(live: live)
        model.start()
        let model = model
        receiver = PhoneRelayReceiver { data in Task { @MainActor in model.receive(data) } }
    }
}
