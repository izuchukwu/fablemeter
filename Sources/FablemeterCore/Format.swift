import Foundation

// MARK: - Formatting

enum Format {
    /// When a limit comes back, as a wall clock reading rather than a countdown:
    /// `5:03 PM` today, `Tue 4 PM` (nearest hour) on a later day. The 12/24-hour
    /// choice follows the user's locale via the `j` template symbol.
    static func resetStamp(
        _ date: Date?,
        from now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let today = calendar.isDate(date, inSameDayAs: now)
        // A later day only needs the hour, so round to the nearest one — a
        // "Tue 3:57 PM" is false precision for something a week out.
        let subject = today
            ? date
            : Date(timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate / 3600).rounded() * 3600)

        let template = today ? "jmm" : "Ej"
        var pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
            ?? (today ? "h:mm a" : "ccc h a")
        if !today {
            // `Ej` comes back as "ccc, h a"; the comma is noise in a narrow
            // column. Drop it but keep the locale's own ordering.
            pattern = pattern.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "  ", with: " ")
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: subject)
    }

    /// Compact countdown: `3d 04h`, `1h 08m`, `12m`, `now`. Only `--probe`
    /// prints this now; the popover shows the reset stamp instead.
    static func countdown(to date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return String(format: "%dd %02dh", days, hours) }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return "\(max(minutes, 1))m"
    }

    static func relative(_ date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
