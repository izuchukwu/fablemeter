import Foundation

/// Plain-language reading of headroom — the verdict shown before any number.
enum Verdict {
    /// `nil` headroom means the fetch succeeded and reported no readings at all.
    /// It is called "No data" rather than "Unknown" on purpose: every other word
    /// this app puts in this slot names something you can act on or wait out —
    /// "rate limited", "No Internet", "Reconnect" — and "Unknown" only names the
    /// app's own confusion. "No data" says whose gap it is: the server sent
    /// none. After the null-versus-zero fix this should be genuinely rare, since
    /// an unused account now reports zeros and reads Available.
    static func word(headroom: Double?) -> String {
        guard let headroom else { return "No data" }
        if headroom > 40 { return "Available" }
        if headroom > 10 { return "Limited" }
        if headroom > 0 { return "Almost out" }
        return "Blocked"
    }

}
