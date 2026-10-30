import Foundation

/// Locale and calendar for all UI copy. The user's own by default; the screenshot renderer pins
/// en_US so README images are the same on every machine.
public enum Display {
    public nonisolated(unsafe) static var locale: Locale = .current
    public nonisolated(unsafe) static var calendar: Calendar = .current
}

/// Shared date formatters by locale + template (DateFormatter is expensive to create).
public enum Formatters {
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    public static func template(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.timeZone.identifier)|\(calendar.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }
}
