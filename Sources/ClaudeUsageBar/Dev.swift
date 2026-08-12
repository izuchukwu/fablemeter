import AppKit
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

        // Blocked draws nothing at all; small-but-real headroom keeps its floor.
        check("blocked gauge is truly empty", BarRenderer.fillHeight(headroom: 0) == 0,
              "got \(BarRenderer.fillHeight(headroom: 0))")
        check("1% keeps the minimum fill",
              BarRenderer.fillHeight(headroom: 1) == BarRenderer.minimumFill,
              "got \(BarRenderer.fillHeight(headroom: 1))")
        check("8% keeps the minimum fill",
              BarRenderer.fillHeight(headroom: 8) == BarRenderer.minimumFill,
              "got \(BarRenderer.fillHeight(headroom: 8))")
        check("50% is half the bar",
              BarRenderer.fillHeight(headroom: 50) == BarRenderer.barHeight / 2,
              "got \(BarRenderer.fillHeight(headroom: 50))")
        check("100% fills the bar",
              BarRenderer.fillHeight(headroom: 100) == BarRenderer.barHeight,
              "got \(BarRenderer.fillHeight(headroom: 100))")

        // Characters are uniform: only the level ever takes a warning colour.
        check("letters are never warning-coloured",
              BarRenderer.glyphColor(anyWarning: true) == .labelColor
              && BarRenderer.glyphColor(anyWarning: true) != .systemRed
              && BarRenderer.glyphColor(anyWarning: true) != .systemOrange)
        check("letters follow the menu bar's own label colour",
              BarRenderer.glyphColor(anyWarning: true)
              == BarRenderer.neutralColor(anyWarning: true))

        // …and that colour has to be resolved against the menu bar, not baked
        // in. Hard white would vanish on a light menu bar, so the letters are
        // checked in both appearances rather than in whichever one is on now.
        func glyphBrightness(_ name: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                value = BarRenderer.glyphColor(anyWarning: true)
                    .usingColorSpace(.sRGB)?.brightnessComponent ?? -1
            }
            return value
        }
        let onDark = glyphBrightness(NSAppearance.Name.darkAqua)
        let onLight = glyphBrightness(NSAppearance.Name.aqua)
        check("letters are light on a dark menu bar", onDark > 0.9, "brightness \(onDark)")
        check("letters are dark on a light menu bar", onLight < 0.1, "brightness \(onLight)")

        // A letter dims only when its account is genuinely out. Stale numbers
        // are not spent numbers, so an unreachable account keeps a full-strength
        // letter — the hollow track is what says its reading is old.
        check("blocked letter dims",
              BarRenderer.glyphAlpha(headroom: 0) == BarRenderer.blockedGlyphAlpha,
              "got \(BarRenderer.glyphAlpha(headroom: 0))")
        check("almost-out letter stays full strength", BarRenderer.glyphAlpha(headroom: 1) == 1)
        check("healthy letter stays full strength", BarRenderer.glyphAlpha(headroom: 85) == 1)
        check("unresolved letter stays full strength", BarRenderer.glyphAlpha(headroom: nil) == 1)
        check("the dim is visible but clearly recessed",
              BarRenderer.blockedGlyphAlpha > 0.3 && BarRenderer.blockedGlyphAlpha < 0.5)

        // Hollow means "no data", painted-but-empty means "the data says zero".
        // The two must therefore never render identically.
        func cell(_ headroom: Double?, unreachable: Bool) -> NSImage {
            BarRenderer.image(for: [
                BarCell(character: "E", headroom: headroom, isUnreachable: unreachable)
            ])
        }
        check("unreachable outlines, healthy zero does not",
              cell(nil, unreachable: true).tiffRepresentation
              != cell(0, unreachable: false).tiffRepresentation)
        // Nothing-yet and out-of-quota both draw an empty painted track, so the
        // letter is the only thing telling them apart — and it has to.
        check("nothing-yet reads differently from blocked",
              cell(nil, unreachable: false).tiffRepresentation
              != cell(0, unreachable: false).tiffRepresentation)
        // And a rate limited account keeps drawing the level it last knew,
        // which is the whole point of holding onto the snapshot.
        check("a stale reading is still drawn inside the hollow track",
              cell(60, unreachable: true).tiffRepresentation
              != cell(nil, unreachable: true).tiffRepresentation)
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

        // …but on screen it still says 0%. Only the reset time becomes a dash,
        // and the headroom maths above keeps skipping it.
        check("absent bucket prints 0%", MetricDisplay.percentText(sentinel) == "0%",
              "got \(MetricDisplay.percentText(sentinel))")
        check("absent bucket's reset is a dash",
              MetricDisplay.resetText(sentinel) == "—",
              "got \(MetricDisplay.resetText(sentinel))")
        check("missing bucket prints 0% and a dash",
              MetricDisplay.percentText(nil) == "0%" && MetricDisplay.resetText(nil) == "—")
        check("real zero prints 0% with its reset",
              MetricDisplay.percentText(realZero) == "0%"
              && MetricDisplay.resetText(realZero) != "—")
        let full = UsageBucket(id: "z", label: "z", percent: 100, resetsAt: Date())
        check("100 prints 100%", MetricDisplay.percentText(full) == "100%",
              "got \(MetricDisplay.percentText(full))")
        check("percents round rather than truncate",
              MetricDisplay.percentText(
                  UsageBucket(id: "r", label: "r", percent: 99.6, resetsAt: Date())
              ) == "100%")

        // The display rule must not leak into the maths: a 0%/no-reset bucket
        // shows 0% and is still not a constraint.
        var displayVsMaths = UsageSnapshot()
        displayVsMaths.fiveHour = UsageBucket(
            id: "session", label: "5-hour", percent: 0, resetsAt: nil
        )
        displayVsMaths.weekly = UsageBucket(
            id: "weekly", label: "Weekly", percent: 40, resetsAt: Date()
        )
        check("0%-shown bucket is still skipped by headroom",
              displayVsMaths.headroom == 60,
              "got \(displayVsMaths.headroom.map { String($0) } ?? "nil")")
        check("…while still printing 0%",
              MetricDisplay.percentText(displayVsMaths.fiveHour) == "0%"
              && MetricDisplay.resetText(displayVsMaths.fiveHour) == "—")

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

        // MARK: Polling budget
        //
        // The whole point of this section is that the app cannot re-trip the
        // rate limit, so the numbers themselves are asserted, not just the
        // shape of the schedule.

        check("base poll interval is 5 minutes", PollPolicy.interval == 300,
              "got \(PollPolicy.interval)s")
        check("accounts are staggered, not burst", PollPolicy.stagger > 0)
        check("the tick never outpaces the interval", PollPolicy.tick < PollPolicy.interval)
        check("opportunistic refreshes coalesce inside a minute",
              PollPolicy.freshness >= 60)
        // Three accounts at the base interval, worst case.
        let perHour = 3.0 * 3600 / PollPolicy.interval
        check("three accounts cost <= 36 requests/hour at rest", perHour <= 36,
              "\(Int(perHour))/hour")

        // 5m -> 10m -> 20m -> 40m -> pinned at the cap.
        let ladder = (1...6).map { Backoff.delay(failures: $0, kind: .rateLimited) }
        check("429 backoff doubles from the base interval",
              ladder[0] == 300 && ladder[1] == 600 && ladder[2] == 1200 && ladder[3] == 2400,
              "got \(ladder.map { Int($0) })")
        check("429 backoff caps between 30 and 60 minutes",
              ladder[4] == Backoff.Failure.rateLimited.cap
              && ladder[5] == Backoff.Failure.rateLimited.cap
              && (1800...3600).contains(Backoff.Failure.rateLimited.cap),
              "cap \(Int(Backoff.Failure.rateLimited.cap))s")
        check("backoff is monotonic", zip(ladder, ladder.dropFirst()).allSatisfy { $0 <= $1 })
        check("no failures means no delay", Backoff.delay(failures: 0, kind: .rateLimited) == 0)
        check("a long outage cannot overflow the ladder",
              Backoff.delay(failures: 500, kind: .rateLimited)
              == Backoff.Failure.rateLimited.cap)

        // Transient failures back off too — more gently, but they do back off,
        // which is what stops a flapping connection spinning the loop.
        let transient = (1...8).map { Backoff.delay(failures: $0, kind: .transient) }
        check("transient backoff starts below the 429 schedule",
              transient[0] < ladder[0], "got \(Int(transient[0]))s")
        check("transient backoff still doubles and caps",
              transient[1] == transient[0] * 2
              && transient[7] == Backoff.Failure.transient.cap,
              "got \(transient.map { Int($0) })")

        // Jitter keeps several accounts that failed together from coming back
        // in lockstep, but must never turn into a shorter wait than intended.
        let low = Backoff.jittered(failures: 1, kind: .rateLimited) { $0.lowerBound }
        let high = Backoff.jittered(failures: 1, kind: .rateLimited) { $0.upperBound }
        check("jitter spreads +/-15% around the delay",
              low == 300 * (1 - Backoff.jitterFraction)
              && high == 300 * (1 + Backoff.jitterFraction),
              "got \(Int(low))s...\(Int(high))s")
        check("jitter never collapses the wait", low > 0 && low < high)
        let rolled = (0..<200).map { _ in Backoff.jittered(failures: 2, kind: .rateLimited) }
        check("random jitter stays inside its band",
              rolled.allSatisfy { $0 >= 600 * 0.85 && $0 <= 600 * 1.15 })

        // Retry-After: seconds, HTTP-date, and nonsense.
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        check("Retry-After in seconds",
              RetryAfter.parse("120", now: epoch) == epoch.addingTimeInterval(120))
        check("Retry-After tolerates whitespace",
              RetryAfter.parse("  90 ", now: epoch) == epoch.addingTimeInterval(90))
        check("Retry-After: 0 is honoured as now",
              RetryAfter.parse("0", now: epoch) == epoch)
        let httpDate = RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT", now: epoch)
        check("Retry-After as an HTTP-date",
              httpDate == Date(timeIntervalSince1970: 1_445_412_480),
              "got \(httpDate.map { "\($0)" } ?? "nil")")
        check("Retry-After rejects nonsense",
              RetryAfter.parse("soon", now: epoch) == nil
              && RetryAfter.parse(nil, now: epoch) == nil
              && RetryAfter.parse("", now: epoch) == nil
              && RetryAfter.parse("-30", now: epoch) == nil)

        // A Retry-After the server actually sent outranks the computed backoff…
        let far = epoch.addingTimeInterval(7200)
        check("Retry-After wins over the computed backoff",
              Backoff.nextAttempt(failures: 1, kind: .rateLimited, retryAfter: far, now: epoch)
              == far)
        // …but cannot pull the next attempt in front of the ordinary interval.
        let soon = epoch.addingTimeInterval(5)
        check("a tiny Retry-After cannot beat the poll interval",
              Backoff.nextAttempt(failures: 1, kind: .rateLimited, retryAfter: soon, now: epoch)
              == epoch.addingTimeInterval(PollPolicy.interval))
        check("a stale Retry-After cannot pull the attempt into the past",
              Backoff.nextAttempt(
                  failures: 3, kind: .rateLimited,
                  retryAfter: epoch.addingTimeInterval(-600), now: epoch
              ) >= epoch)

        // The per-account schedule: climbing, blocking, and wiped by one success.
        var schedule = RetrySchedule()
        check("a fresh account is not backed off",
              !schedule.isBackedOff && !schedule.isBlocked(at: epoch))
        schedule.recordFailure(.rateLimited, now: epoch) { _ in 0 }
        check("one 429 blocks for the base interval",
              schedule.blockedUntil == epoch.addingTimeInterval(300)
              && schedule.isBlocked(at: epoch.addingTimeInterval(299)),
              "blocked until \(schedule.blockedUntil.map { "\($0)" } ?? "nil")")
        check("the block expires on time",
              !schedule.isBlocked(at: epoch.addingTimeInterval(301)))
        schedule.recordFailure(.rateLimited, now: epoch) { _ in 0 }
        schedule.recordFailure(.rateLimited, now: epoch) { _ in 0 }
        check("consecutive 429s climb the ladder",
              schedule.failures == 3
              && schedule.blockedUntil == epoch.addingTimeInterval(1200),
              "failures \(schedule.failures)")
        schedule.recordSuccess()
        check("one success resets the whole schedule",
              schedule.failures == 0 && schedule.blockedUntil == nil
              && !schedule.isBlocked(at: epoch) && !schedule.isBackedOff)
        schedule.recordFailure(.rateLimited, now: epoch) { _ in 0 }
        check("the ladder restarts from the base after a reset",
              schedule.blockedUntil == epoch.addingTimeInterval(300))

        // How stale each reason tolerates. Manual overrides staleness but is
        // not allowed to escape backoff — that gate lives in `isDue`.
        check("scheduled refreshes wait a full interval",
              RefreshReason.scheduled.maxAge == PollPolicy.interval)
        check("opportunistic refreshes coalesce under a minute",
              RefreshReason.opportunistic.maxAge == PollPolicy.freshness)
        check("manual refresh ignores staleness", RefreshReason.manual.maxAge == nil)
        check("a 429 still carries no Retry-After when the server sends none",
              {
                  if case .rateLimited(let after) = UsageError.rateLimited(retryAfter: nil) {
                      return after == nil
                  }
                  return false
              }())
        check("rate limited still reads as 'rate limited'",
              UsageError.rateLimited(retryAfter: nil).errorDescription == "rate limited")

        // A failure must not destroy the reading already on screen.
        var live = AccountState(snapshot: snap, error: nil)
        check("a healthy account is not stale", !live.isStale)
        live.error = "rate limited"
        check("a rate limited account keeps its last snapshot", live.snapshot != nil)
        check("…and is marked stale rather than blank", live.isStale)
        check("…and still reports its last known headroom", live.snapshot?.headroom == 26)
        let neverLoaded = AccountState(snapshot: nil, error: "rate limited")
        check("only a never-loaded account has nothing to show",
              neverLoaded.snapshot == nil && !neverLoaded.isStale)

        // Ordering. The array's order is the menu bar's order, left to right.
        let p = Account(email: "p@personal.com", nickname: "Personal", label: "P", refreshToken: "x")
        let w = Account(email: "w@work.example", nickname: "Work", label: "W", refreshToken: "x")
        let t = Account(email: "t@team.example", nickname: "Team", label: "T", refreshToken: "x")
        let list = [p, w, t]
        func labels(_ accounts: [Account]?) -> String {
            accounts.map { $0.map(\.label).joined() } ?? "nil"
        }

        check("move down", labels(AccountOrder.shifted(list, id: p.id, by: 1)) == "WPT",
              "got \(labels(AccountOrder.shifted(list, id: p.id, by: 1)))")
        check("move up", labels(AccountOrder.shifted(list, id: t.id, by: -1)) == "PTW",
              "got \(labels(AccountOrder.shifted(list, id: t.id, by: -1)))")
        check("move up at the front refused", AccountOrder.shifted(list, id: p.id, by: -1) == nil)
        check("move down at the end refused", AccountOrder.shifted(list, id: t.id, by: 1) == nil)
        check("zero delta refused", AccountOrder.shifted(list, id: w.id, by: 0) == nil)
        check("unknown id refused", AccountOrder.shifted(list, id: UUID(), by: 1) == nil)
        // Two moves in a row compose, so a menu-driven walk lands where a drag would.
        let walked = AccountOrder.shifted(list, id: t.id, by: -1).flatMap {
            AccountOrder.shifted($0, id: t.id, by: -1)
        }
        check("repeated moves compose", labels(walked) == "TPW", "got \(labels(walked))")

        check("drag last onto first", labels(AccountOrder.moved(list, id: t.id, onto: p.id)) == "TPW",
              "got \(labels(AccountOrder.moved(list, id: t.id, onto: p.id)))")
        check("drag first onto last", labels(AccountOrder.moved(list, id: p.id, onto: t.id)) == "WTP",
              "got \(labels(AccountOrder.moved(list, id: p.id, onto: t.id)))")
        check("drop onto self refused", AccountOrder.moved(list, id: w.id, onto: w.id) == nil)
        check("drop from outside refused", AccountOrder.moved(list, id: UUID(), onto: w.id) == nil)
        check("reorder keeps every account",
              Set(AccountOrder.moved(list, id: t.id, onto: p.id)?.map(\.id) ?? []) == Set(list.map(\.id)))

        // The order has to survive the trip through disk, since that is the only
        // thing carrying it across a relaunch. Runs against a temporary
        // directory so the user's own accounts.json is never touched.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeUsageBarSelfTest-\(UUID().uuidString)", isDirectory: true)
        Store.directoryOverride = sandbox
        Store.save(list)
        check("store round-trips order", labels(Store.load()) == "PWT", "got \(labels(Store.load()))")
        if let reordered = AccountOrder.moved(list, id: t.id, onto: p.id) {
            Store.save(reordered)
        }
        let reloaded = Store.load()
        check("reorder round-trips order", labels(reloaded) == "TPW", "got \(labels(reloaded))")
        check("reorder keeps identities across the store",
              reloaded.map(\.id) == [t.id, p.id, w.id])
        check("reorder keeps labels and nicknames",
              reloaded.map(\.nickname) == ["Team", "Personal", "Work"])
        let mode = (try? FileManager.default.attributesOfItem(atPath: Store.file.path)[.posixPermissions])
            .flatMap { $0 as? NSNumber }?.intValue
        check("accounts.json stays 0600", mode == 0o600, "got \(mode.map { String($0, radix: 8) } ?? "nil")")
        try? FileManager.default.removeItem(at: sandbox)
        Store.directoryOverride = nil
        check("selftest sandbox cleaned up", !FileManager.default.fileExists(atPath: sandbox.path))

        print(failures == 0 ? "\nselftest: all checks passed" : "\nselftest: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Appearance render

/// Draws the status item image for every state, in both menu bar appearances,
/// onto the backdrop each one actually sits on. The real menu bar takes its
/// appearance from the desktop picture behind it, so a machine with a dark
/// wallpaper can never show the light case on screen — this renders it instead.
enum RenderStates {
    static func run(into directory: String) -> Int32 {
        let cells = [
            BarCell(character: "P", headroom: 0, isUnreachable: false),    // blocked
            BarCell(character: "W", headroom: 22, isUnreachable: true),    // stale
            BarCell(character: "T", headroom: 85, isUnreachable: false),   // healthy
            BarCell(character: "X", headroom: nil, isUnreachable: true),   // never loaded
            BarCell(character: "F", headroom: 100, isUnreachable: false)   // full
        ]
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for (name, backdrop) in [
            (NSAppearance.Name.aqua, NSColor(white: 0.94, alpha: 1)),
            (NSAppearance.Name.darkAqua, NSColor(white: 0.12, alpha: 1))
        ] {
            guard let appearance = NSAppearance(named: name) else { continue }
            var bar: NSImage?
            appearance.performAsCurrentDrawingAppearance {
                bar = BarRenderer.image(for: cells, appearance: appearance)
            }
            guard let bar else { continue }

            // A template image carries no colour of its own, so tint it the way
            // the menu bar would before compositing it onto the backdrop.
            let scale: CGFloat = 8
            let canvas = NSImage(
                size: NSSize(width: bar.size.width * scale, height: bar.size.height * scale)
            )
            canvas.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .none
            backdrop.setFill()
            NSRect(origin: .zero, size: canvas.size).fill()
            let target = NSRect(origin: .zero, size: canvas.size)
            if bar.isTemplate {
                let tint = name == .darkAqua ? NSColor.white : NSColor.black
                bar.draw(in: target)
                tint.set()
                target.fill(using: .sourceAtop)
            } else {
                bar.draw(in: target)
            }
            canvas.unlockFocus()

            let file = url.appendingPathComponent("states-\(name.rawValue).png")
            if let tiff = canvas.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?
                   .representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("wrote \(file.path)")
            }
        }
        return 0
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
