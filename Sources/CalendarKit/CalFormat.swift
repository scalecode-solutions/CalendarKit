import Foundation

/// Shared date formatters. Making a DateFormatter costs tens of microseconds
/// plus locale loading, and rows, headers and the reminder planner made one
/// per call on every rebuild (R49). DateFormatter is thread-safe to use once
/// configured; the cache is keyed by locale too, so a language change gets
/// fresh ones.
enum CalFormat {
    static let utc = TimeZone(identifier: "UTC")!

    /// A localized format from a template ("EEEEMMMMd"), in `zone`.
    static func template(_ template: String, zone: TimeZone = utc) -> DateFormatter {
        cache.get("t|\(template)|\(zone.identifier)") { f in
            f.timeZone = zone
            f.setLocalizedDateFormatFromTemplate(template)
        }
    }

    /// Date and time styles, in `zone`.
    static func styles(date: DateFormatter.Style, time: DateFormatter.Style, zone: TimeZone = .current) -> DateFormatter {
        cache.get("s|\(date.rawValue)|\(time.rawValue)|\(zone.identifier)") { f in
            f.timeZone = zone
            f.dateStyle = date
            f.timeStyle = time
        }
    }

    private static let cache = FormatterCache()
}

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    func get(_ key: String, configure: (DateFormatter) -> Void) -> DateFormatter {
        let k = "\(Locale.current.identifier)|\(key)"
        lock.lock()
        defer { lock.unlock() }
        if let f = formatters[k] { return f }
        let f = DateFormatter()
        f.locale = .current
        configure(f)
        formatters[k] = f
        return f
    }
}
