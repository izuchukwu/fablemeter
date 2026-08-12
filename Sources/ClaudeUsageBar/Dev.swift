import Foundation

// MARK: - Fixture

/// A real `/api/oauth/usage` response, captured verbatim. Embedded as a string
/// rather than a resource bundle so the hand-assembled .app stays a single binary.
enum Fixture {
    static let usageJSON = """
    {
      "five_hour": { "utilization": 74.0, "resets_at": "2026-08-12T01:40:00.087143+00:00",
                     "limit_dollars": null, "used_dollars": null, "remaining_dollars": null },
      "seven_day": { "utilization": 15.0, "resets_at": "2026-08-15T03:00:00.087163+00:00" },
      "seven_day_oauth_apps": null, "seven_day_opus": null, "seven_day_sonnet": null,
      "seven_day_cowork": null, "seven_day_omelette": null,
      "bucket_a": null, "bucket_b": null, "bucket_c": null,
      "bucket_d": { "utilization": 0.0, "resets_at": null },
      "bucket_e": null, "bucket_f": null,
      "extra_usage": { "is_enabled": false, "used_credits": 210665.0, "currency": "USD" },
      "limits": [
        { "kind": "session",       "group": "session", "percent": 74, "severity": "normal",
          "resets_at": "2026-08-12T01:40:00.087143+00:00", "scope": null, "is_active": true },
        { "kind": "weekly_all",    "group": "weekly",  "percent": 15, "severity": "normal",
          "resets_at": "2026-08-15T03:00:00.087163+00:00", "scope": null, "is_active": false },
        { "kind": "weekly_scoped", "group": "weekly",  "percent": 25, "severity": "normal",
          "resets_at": "2026-08-15T03:00:00.087376+00:00",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
          "is_active": false }
      ],
      "member_dashboard_available": false
    }
    """
}

// MARK: - Self test

enum SelfTest {
    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  \(detail)")")
            if !ok { failures += 1 }
        }

        let stamp = "2026-08-12T01:40:00.087143+00:00"
        let parsed = ISODate.parse(stamp)
        check("microsecond ISO-8601 parses", parsed != nil, parsed.map { "-> \($0)" } ?? "-> nil")
        check("millisecond ISO-8601 parses", ISODate.parse("2026-08-12T01:40:00.087+00:00") != nil)
        check("no-fraction ISO-8601 parses", ISODate.parse("2026-08-12T01:40:00Z") != nil)
        check("nil / empty rejected", ISODate.parse(nil) == nil && ISODate.parse("") == nil)

        guard let snap = try? UsageDecoder.decode(Data(Fixture.usageJSON.utf8)) else {
            print("FAIL  fixture decodes")
            return 1
        }
        print("PASS  fixture decodes")

        check("5-hour == 74", snap.fiveHour?.percent == 74, "got \(snap.fiveHour.map { String($0.percent) } ?? "nil")")
        check("weekly == 15", snap.weekly?.percent == 15, "got \(snap.weekly.map { String($0.percent) } ?? "nil")")
        let fable = snap.scoped(named: "Fable")
        check("Fable == 25", fable?.percent == 25, "got \(fable.map { String($0.percent) } ?? "nil")")
        check("5-hour reset parsed", snap.fiveHour?.resetsAt != nil, snap.fiveHour?.resetsAt.map { "\($0)" } ?? "")
        check("weekly reset parsed", snap.weekly?.resetsAt != nil, snap.weekly?.resetsAt.map { "\($0)" } ?? "")
        check("Fable reset parsed", fable?.resetsAt != nil, fable?.resetsAt.map { "\($0)" } ?? "")
        check("scoped bucket count == 1", snap.scoped.count == 1, "got \(snap.scoped.count)")
        check("percents not rescaled", snap.fiveHour?.percent ?? 0 <= 100)

        // headroom = min(100-74, 100-15, 100-25) = 26
        check("headroom == 26", snap.headroom == 26, "got \(snap.headroom.map { String($0) } ?? "nil")")

        // Absent buckets must be skipped, not counted as 0 or 100.
        var partial = UsageSnapshot()
        partial.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: 90, resetsAt: Date())
        partial.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: 0, resetsAt: nil)]
        check("absent buckets skipped", partial.headroom == 10, "got \(partial.headroom.map { String($0) } ?? "nil")")
        check("nothing resolved -> nil headroom", UsageSnapshot().headroom == nil)

        // Menu bar colour tiers.
        check("headroom 85 is monochrome", BarRenderer.warningColor(for: 85) == nil)
        check("headroom 30 is monochrome", BarRenderer.warningColor(for: 30) == nil)
        check("headroom 25 is orange", BarRenderer.warningColor(for: 25) == .systemOrange)
        check("headroom 8 is red", BarRenderer.warningColor(for: 8) == .systemRed)
        check("verdicts", Verdict.word(headroom: 85) == "Available"
            && Verdict.word(headroom: 30) == "Limited"
            && Verdict.word(headroom: 8) == "Almost out"
            && Verdict.word(headroom: 0) == "Blocked")

        // Account defaults derive from the email's local part.
        let account = Account(email: "izu@personal.com", refreshToken: "x")
        check("default nickname", account.nickname == "Izu", "got \(account.nickname)")
        check("default label", account.label == "I", "got \(account.label)")
        check("label normalizes", Account.normalizeLabel(" work ") == "W")

        // "no data" sentinel: 0% with a null reset must not read as a real 0%.
        let sentinel = UsageBucket(id: "x", label: "x", percent: 0, resetsAt: nil)
        check("zero/null sentinel is absent", sentinel.hasData == false)
        let realZero = UsageBucket(id: "y", label: "y", percent: 0, resetsAt: Date())
        check("zero with reset is present", realZero.hasData == true)

        // String and Int percents must both coerce.
        check("string percent coerces", JSONScalar.number("42") == 42)
        check("int percent coerces", JSONScalar.number(7) == 7)

        // Flat-key fallback when limits[] is missing.
        let flatOnly = #"{"five_hour":{"utilization":"63","resets_at":"2026-08-12T01:40:00.087143+00:00"},"seven_day":{"utilization":9,"resets_at":null}}"#
        let flat = try? UsageDecoder.decode(Data(flatOnly.utf8))
        check("flat fallback 5-hour == 63", flat?.fiveHour?.percent == 63)
        check("flat fallback weekly == 9", flat?.weekly?.percent == 9)

        // Countdown survives only for `--probe`'s output; the popover shows stamps.
        check("countdown days", Format.countdown(to: Date().addingTimeInterval(3 * 86400 + 4 * 3600 + 60)) == "3d 04h")
        check("countdown hours", Format.countdown(to: Date().addingTimeInterval(3600 + 8 * 60 + 1)) == "1h 08m")
        check("countdown minutes", Format.countdown(to: Date().addingTimeInterval(12 * 60 + 1)) == "12m")
        check("countdown nil", Format.countdown(to: nil) == "—")

        // Reset stamps. Fixed locale + zone so the expectations are stable
        // wherever this runs; 2026-08-11 is a Tuesday, 2026-08-13 a Thursday.
        let zone = TimeZone(identifier: "America/Chicago")!
        var fixed = Calendar(identifier: .gregorian)
        fixed.timeZone = zone
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            fixed.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: hour, minute: minute
            ))!
        }
        func reset(_ date: Date?, _ identifier: String, from: Date) -> String {
            // ICU separates the AM/PM marker with a narrow no-break space —
            // right on screen, but not something to hardcode into a literal.
            Format.resetStamp(date, from: from, locale: Locale(identifier: identifier), timeZone: zone)
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let noon = at(8, 11, 12, 0)

        let todayStamp = reset(at(8, 11, 17, 3), "en_US", from: noon)
        check("reset today -> clock time", todayStamp == "5:03 PM", "got \(todayStamp)")
        let midnightish = reset(at(8, 11, 0, 7), "en_US", from: noon)
        check("reset earlier today keeps the day", midnightish == "12:07 AM", "got \(midnightish)")
        let laterUp = reset(at(8, 13, 16, 40), "en_US", from: noon)
        check("later day rounds up to the hour", laterUp == "Thu 5 PM", "got \(laterUp)")
        let laterDown = reset(at(8, 13, 16, 20), "en_US", from: noon)
        check("later day rounds down to the hour", laterDown == "Thu 4 PM", "got \(laterDown)")
        let tomorrow = reset(at(8, 12, 1, 40), "en_US", from: noon)
        check("tomorrow is never a bare clock time", tomorrow == "Wed 2 AM", "got \(tomorrow)")
        // 12/24-hour follows the locale rather than being hardcoded.
        let today24 = reset(at(8, 11, 17, 3), "en_GB", from: noon)
        check("24-hour locale, today", today24 == "17:03", "got \(today24)")
        let later24 = reset(at(8, 13, 16, 40), "en_GB", from: noon)
        check("24-hour locale, later day", later24 == "Thu 17", "got \(later24)")
        check("reset stamp nil", Format.resetStamp(nil) == "—")

        print(failures == 0 ? "\nselftest: all checks passed" : "\nselftest: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Live probe

/// Dev affordance: borrows Claude Code's existing access token read-only to
/// exercise the network + decode path. Never writes to or refreshes the
/// keychain, and never prints the token.
enum Probe {
    static func run() async -> Int32 {
        guard let token = keychainAccessToken() else {
            print("probe: could not read Claude Code credentials from the keychain")
            return 1
        }
        print("probe: token loaded from keychain (\(token.count) chars, not shown)")
        do {
            let snap = try await UsageClient.fetch(accessToken: token)
            print("probe: HTTP 200, decoded buckets:")
            show("5-hour", snap.fiveHour)
            show("Weekly", snap.weekly)
            if snap.scoped.isEmpty { print("  (no weekly_scoped buckets)") }
            for bucket in snap.scoped { show(bucket.label, bucket) }
            let headroom = snap.headroom.map { "\(Int($0.rounded()))%" } ?? "unknown"
            print("probe: headroom = \(headroom)  ->  \(Verdict.word(headroom: snap.headroom))")
            return 0
        } catch {
            print("probe: failed — \(error.localizedDescription)")
            return 1
        }
    }

    private static func show(_ label: String, _ bucket: UsageBucket?) {
        guard let bucket, bucket.hasData else {
            print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) —")
            return
        }
        let reset = bucket.resetsAt.map { "resets \(Format.countdown(to: $0)) (\($0))" } ?? "no reset"
        print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(Int(bucket.percent.rounded()))%  \(reset)")
    }

    private static func keychainAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-a", NSUserName(), "-w", "-s", "Claude Code-credentials"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}
