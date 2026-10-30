import HeadroomKit
import SwiftUI

/// An iPhone Lock Screen with Headroom's complications and session Live Activity, drawn from a
/// feed. The Mac shows it in Settings → iPhone & Watch; the preview renderer uses it for review.
public struct LockScreenPreview: View {
    public var feed: WidgetFeed
    public var now: Date

    public init(feed: WidgetFeed, now: Date) { self.feed = feed; self.now = now }

    public var body: some View {
        let focus = feed.focus
        let others = feed.providers.filter { ($0.week != nil || $0.session != nil) && $0.key != focus?.key }
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.31), Color(red: 0.23, green: 0.16, blue: 0.36),
                                    Color(red: 0.06, green: 0.18, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 44)
                Text(now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 76, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                HStack(spacing: 10) {
                    ComplicationView(kind: .session, shape: .circular, provider: focus, generatedAt: feed.generatedAt, now: now)
                        .frame(width: 60, height: 60)
                    ComplicationView(kind: .week, shape: .circular, provider: focus, generatedAt: feed.generatedAt, now: now)
                        .frame(width: 60, height: 60)
                    ComplicationView(kind: .pace, shape: .rectangular, provider: focus, second: others.first, generatedAt: feed.generatedAt, now: now)
                        .frame(width: 150, height: 66)
                }
                .foregroundStyle(.white)
                .environment(\.accessoryTint, .mono)
                .padding(.top, 6)
                Spacer()
                if let focus, let state = SessionActivityState.from(focus, generatedAt: feed.generatedAt) {
                    SessionActivityLockScreen(provider: focus.id, label: focus.shortLabel ?? focus.id.displayName, state: state, now: now)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.42)))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 54)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.staticTimers, true)
    }
}
