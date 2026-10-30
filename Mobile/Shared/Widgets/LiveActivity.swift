#if os(iOS)
import ActivityKit
import AppIntents
import HeadroomKit
import HeadroomWidgetUI
import SwiftUI
import WidgetKit

/// The 5-hour session on the Lock Screen, in the Dynamic Island, in StandBy and (through the
/// iPhone) in the Apple Watch Smart Stack.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionActivityContent(attributes: context.attributes, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "headroom://account/\(context.attributes.accountID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        SessionActivityRing(state: context.state, width: 3).frame(width: 28, height: 28)
                        Text("\(Int((context.state.left * 100).rounded()))%").font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(now: Date(), to: context.state.resetsAt).font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.shortLabel).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SessionActivityExpandedBottom(state: context.state)
                }
            } compactLeading: {
                SessionActivityCompactLeading(provider: context.attributes.provider, state: context.state)
            } compactTrailing: {
                SessionActivityCompactTrailing(state: context.state)
            } minimal: {
                SessionActivityRing(state: context.state).frame(width: 18, height: 18)
            }
            .widgetURL(URL(string: "headroom://account/\(context.attributes.accountID)"))
            .keylineTint(Palette(.dark).tone(context.state.tone).text)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen layout, or the Watch Smart Stack's when the family is small.
struct SessionActivityContent: View {
    var attributes: SessionActivityAttributes
    var state: SessionActivityState
    var stale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            SessionActivityWatch(provider: attributes.provider, state: state).padding(8)
        default:
            SessionActivityLockScreen(provider: attributes.provider, label: attributes.shortLabel, state: state)
                .opacity(stale ? 0.7 : 1)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Control Center: start or stop tracking the most urgent account's session.
struct TrackSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.scalexy.headroom.control.track") {
            ControlWidgetButton(action: TrackSessionIntent()) {
                Label("Track 5-Hour Session", systemImage: "livephoto")
            }
        }
        .displayName("Track 5-Hour Session")
        .description("Shows the 5-hour session on the Lock Screen, or stops showing it.")
    }
}
#endif
