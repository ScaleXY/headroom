import AppIntents
import Foundation
import HeadroomKit

// Compiled into the iOS and watchOS apps and both widget extensions, so App Intents metadata is
// extracted per target. `HEADROOM_APP` marks the app targets, where intents that act really act.

/// A provider account, from the feed the app leaves in the App Group.
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = AccountQuery()

    var id: String
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ p: WidgetProvider) {
        id = p.key
        title = p.email ?? p.id.displayName
        subtitle = [p.email == nil ? nil : p.id.displayName, p.plan].compactMap { $0 }.joined(separator: " · ")
    }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let feed = FeedFile.read()
        return identifiers.compactMap { id in feed?.account(id).map(AccountEntity.init) }
    }

    /// Accounts signed in on some Mac, most urgent first.
    func suggestedEntities() async throws -> [AccountEntity] {
        guard let feed = FeedFile.read() else { return [] }
        let live = feed.providers.filter { ($0.week != nil || $0.session != nil) && $0.isActive != false }
        let first = feed.focus?.key
        return live.sorted { a, _ in a.key == first }.map(AccountEntity.init)
    }
}

/// Configures a widget or complication: one account, or the one that needs watching most.
struct SelectAccountIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Account"
    static let description = IntentDescription("Show one account, or leave it empty for whichever needs watching most.")

    @Parameter(title: "Account")
    var account: AccountEntity?

    init() {}
    init(account: AccountEntity?) { self.account = account }
}

enum ProviderFilterOption: String, AppEnum {
    case all, claude, codex

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [ProviderFilterOption: DisplayRepresentation] = [
        .all: "Claude and Codex", .claude: "Claude", .codex: "Codex",
    ]
}

/// Configures the Accounts widget.
struct AccountsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Accounts"
    static let description = IntentDescription("Which accounts to list.")

    @Parameter(title: "Show", default: .all)
    var provider: ProviderFilterOption

    @Parameter(title: "Include accounts not signed in on any Mac", default: false)
    var includeInactive: Bool

    init() {}
}

/// "How much Claude is left?": a sentence for Siri and Shortcuts.
struct CheckHeadroomIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Headroom"
    static let description = IntentDescription("Says how much of the week and the 5-hour session is left.")

    @Parameter(title: "Account")
    var account: AccountEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let feed = FeedFile.read(), let p = account.flatMap({ feed.account($0.id) }) ?? feed.focus else {
            let text = "Headroom hasn't heard from your Mac yet."
            return .result(value: text, dialog: "\(text)")
        }
        let text = Self.sentence(p, now: Date())
        return .result(value: text, dialog: "\(text)")
    }

    static func sentence(_ p: WidgetProvider, now: Date) -> String {
        var parts: [String] = []
        let name = p.shortLabel ?? p.id.displayName
        if let w = p.week {
            parts.append("\(name) has \(Int((w.left * 100).rounded())) percent left this week, \(w.state.word)")
        }
        if let s = p.session, let resetsAt = s.resetsAt, resetsAt > now, !s.isIdle {
            parts.append("the 5-hour session is \(Int((s.used * 100).rounded())) percent used and resets in \(TimeFormat.spokenSpan(resetsAt.timeIntervalSince(now)))")
        }
        return parts.isEmpty ? "\(name) has no reading yet." : parts.joined(separator: "; ") + "."
    }
}

#if os(iOS)
/// Starts the 5-hour session Live Activity for an account, or stops it when it's running.
/// Runs in the app's process (that's what `LiveActivityIntent` is for), even from a widget button.
struct TrackSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Track 5-Hour Session"
    static let description = IntentDescription("Shows the 5-hour session on the Lock Screen and in the Dynamic Island, or stops showing it.")

    @Parameter(title: "Account")
    var account: AccountEntity?

    init() {}
    init(accountID: String?) {
        account = accountID.flatMap { id in FeedFile.read()?.account(id).map(AccountEntity.init) }
    }

    func perform() async throws -> some IntentResult {
        #if HEADROOM_APP
        await AppServices.toggleTracking(account?.id)
        #endif
        return .result()
    }
}
#endif
