import SwiftUI
import WidgetKit

/// The iPhone and iPad widgets: Home Screen and StandBy, Lock Screen complications, the session
/// Live Activity and a Control Center control. They read `feed.json`, which the app keeps current.
@main
struct HeadroomMobileWidgets: WidgetBundle {
    var body: some Widget {
        PaceHomeWidget()
        SessionHomeWidget()
        BurnHomeWidget()
        AccountsHomeWidget()
        ActivityHomeWidget()
        SessionComplication()
        WeekComplication()
        PaceComplication()
        BurnComplication()
        SessionLiveActivity()
        TrackSessionControl()
    }
}
