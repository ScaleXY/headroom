import SwiftUI
import WidgetKit

/// The watch-face complications and Smart Stack widget: the same ones as the iPhone Lock Screen.
@main
struct HeadroomWatchWidgets: WidgetBundle {
    var body: some Widget {
        SessionComplication()
        WeekComplication()
        PaceComplication()
        BurnComplication()
    }
}
