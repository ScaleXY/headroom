#if os(iOS)
import ActivityKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

/// The most pressing live agent run on the Lock Screen, in the Dynamic Island and (through the
/// iPhone) in the Apple Watch Smart Stack. The app starts, updates and ends it as syncs arrive.
struct RunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunActivityContent(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "headroom://runs"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RunActivityRing(state: context.state, width: 3).frame(width: 28, height: 28)
                        Text(context.state.figure).font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunStateCapsule(context.state.stateText, hue: context.state.hue, compact: true)
                        .environment(\.colorScheme, .dark).frame(maxWidth: 150, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunActivityExpandedBottom(state: context.state)
                }
            } compactLeading: {
                RunActivityCompactLeading(state: context.state)
            } compactTrailing: {
                RunActivityCompactTrailing(state: context.state)
            } minimal: {
                RunActivityRing(state: context.state).frame(width: 18, height: 18)
            }
            .widgetURL(URL(string: "headroom://runs"))
            .keylineTint(Palette(.dark).run(context.state.hue))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen layout, or the Watch Smart Stack's when the family is small.
struct RunActivityContent: View {
    var state: RunActivityState
    var stale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            RunActivityWatch(state: state).padding(8)
        default:
            RunActivityLockScreen(state: state)
                .opacity(stale ? 0.7 : 1)
                .environment(\.colorScheme, .dark)
        }
    }
}
#endif
