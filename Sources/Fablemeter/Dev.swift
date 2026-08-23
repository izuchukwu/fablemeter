import AppKit
import Foundation
import SwiftUI

// MARK: - Fixture

/// A real `/api/oauth/usage` response — the shape is captured as-is, but the
/// undocumented bucket keys (`bucket_a`…`bucket_f`) are renamed placeholders:
/// their real names are internal identifiers that do not belong in a public
/// repo, and the decoder ignores unknown keys either way. Embedded as a string
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

        /// Every reading is optional now, so the failure detail has to be able
        /// to print "the server sent nothing" as its own value.
        func reading(_ value: Double?) -> String { value.map { String($0) } ?? "null" }

        check("5-hour == 74", snap.fiveHour?.percent == 74, "got \(reading(snap.fiveHour?.percent))")
        check("weekly == 15", snap.weekly?.percent == 15, "got \(reading(snap.weekly?.percent))")
        let fable = snap.scoped(named: "Fable")
        check("Fable == 25", fable?.percent == 25, "got \(reading(fable?.percent))")
        check("5-hour reset parsed", snap.fiveHour?.resetsAt != nil, snap.fiveHour?.resetsAt.map { "\($0)" } ?? "")
        check("weekly reset parsed", snap.weekly?.resetsAt != nil, snap.weekly?.resetsAt.map { "\($0)" } ?? "")
        check("Fable reset parsed", fable?.resetsAt != nil, fable?.resetsAt.map { "\($0)" } ?? "")
        check("scoped bucket count == 1", snap.scoped.count == 1, "got \(snap.scoped.count)")
        check("percents not rescaled", snap.fiveHour?.percent ?? 0 <= 100)

        // headroom = min(100-74, 100-15, 100-25) = 26
        check("headroom == 26", snap.headroom == 26, "got \(snap.headroom.map { String($0) } ?? "nil")")

        // MARK: A null reading and a reported zero are different facts
        //
        // The one distinction this whole file turns on. `percent` is carried as
        // an optional from decoding to drawing, because collapsing null into 0
        // is what made an account the server had simply never reported on look
        // exactly like an account it had reported as untouched — and then made
        // both of them read "Unknown".

        // Same id, same label, same absent window: the reading is the only thing
        // that differs, which is exactly what used to be thrown away.
        let unreported = UsageBucket(id: "b", label: "b", percent: nil, resetsAt: nil)
        let reportedZero = UsageBucket(id: "b", label: "b", percent: 0, resetsAt: nil)
        let zeroWithWindow = UsageBucket(id: "b", label: "b", percent: 0, resetsAt: Date())
        check("a null percent is not a reading", unreported.hasData == false)
        check("a reported zero is a reading, window or no window",
              reportedZero.hasData && zeroWithWindow.hasData)
        check("null and zero are not the same bucket", unreported != reportedZero)
        check("a null percent survives decoding as null, not as 0",
              unreported.percent == nil && reportedZero.percent == 0)

        // Buckets with no reading must be skipped, not counted as 0 or 100.
        var partial = UsageSnapshot()
        partial.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: 90, resetsAt: Date())
        partial.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: nil, resetsAt: nil)]
        check("unreported buckets skipped", partial.headroom == 10, "got \(reading(partial.headroom))")
        check("nothing resolved -> nil headroom", UsageSnapshot().headroom == nil)

        // …while a reported zero is a whole window in hand, so it is a real
        // constraint of 100 — and an account reporting nothing but zeros is
        // Available, which is the bug this fixes.
        var untouched = UsageSnapshot()
        untouched.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: 0, resetsAt: nil)
        untouched.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: 0, resetsAt: nil)
        untouched.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: 0, resetsAt: nil)]
        check("an account reporting all zeros has full headroom",
              untouched.headroom == 100, "got \(reading(untouched.headroom))")
        check("…and reads Available, not No data",
              Verdict.word(headroom: untouched.headroom) == "Available",
              "got \(Verdict.word(headroom: untouched.headroom))")
        // The same three buckets with null readings instead: nothing resolves,
        // and only *that* is the no-data state.
        var reportedNothing = UsageSnapshot()
        reportedNothing.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: nil, resetsAt: nil)
        reportedNothing.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: nil, resetsAt: nil)
        reportedNothing.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: nil, resetsAt: nil)]
        check("null readings resolve to no headroom at all",
              reportedNothing.headroom == nil)
        check("…which is the one state called No data",
              Verdict.word(headroom: reportedNothing.headroom) == "No data",
              "got \(Verdict.word(headroom: reportedNothing.headroom))")
        // "Unknown" is gone: it named the app's own confusion, where every other
        // word in this slot names something to do or to wait out.
        check("no state is called Unknown any more",
              [nil, 0, 8, 30, 85].allSatisfy { Verdict.word(headroom: $0) != "Unknown" })
        // A zero payload and a null payload must not resolve to the same verdict
        // — that equivalence *was* the bug.
        check("all-zero and all-null do not read the same",
              Verdict.word(headroom: untouched.headroom)
              != Verdict.word(headroom: reportedNothing.headroom))
        // One live bucket is enough to leave the no-data state, even if the
        // others said nothing.
        var oneReading = reportedNothing
        oneReading.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: 60, resetsAt: Date())
        check("a single reading is enough to resolve", oneReading.headroom == 40,
              "got \(reading(oneReading.headroom))")

        // Decoding has to preserve the distinction end to end, not just the
        // model: `"percent": null` and `"percent": 0` are different payloads.
        let nullPayload = #"{"limits":[{"kind":"session","percent":null,"resets_at":null}]}"#
        let zeroPayload = #"{"limits":[{"kind":"session","percent":0,"resets_at":null}]}"#
        let decodedNull = try? UsageDecoder.decode(Data(nullPayload.utf8))
        let decodedZero = try? UsageDecoder.decode(Data(zeroPayload.utf8))
        check("a null percent decodes to null", decodedNull?.fiveHour?.percent == nil
              && decodedNull?.fiveHour != nil)
        check("a zero percent decodes to zero", decodedZero?.fiveHour?.percent == 0)
        check("the two payloads produce different headroom",
              decodedNull?.headroom == nil && decodedZero?.headroom == 100)

        // MARK: The structural log line
        //
        // The line that makes this diagnosable next time without spending a
        // refresh token on a live request. It has to carry the one distinction
        // the decoded snapshot no longer shows on screen, stay a single line,
        // and carry nothing from `accounts.json` but the menu bar label.
        let fixtureLine = UsageLog.line(label: "C", snapshot: snap)
        check("the log line names the kinds the payload actually carried",
              fixtureLine.contains("kinds=session,weekly_all,weekly_scoped"),
              fixtureLine)
        check("…and the readings, with their windows",
              fixtureLine.contains("5-hour=74/window")
              && fixtureLine.contains("weekly=15/window")
              && fixtureLine.contains("Fable=25/window"),
              fixtureLine)
        check("…and the headroom it resolved to", fixtureLine.contains("headroom=26"), fixtureLine)
        check("the log line is one line", !fixtureLine.contains("\n"))
        check("the log line carries no credential and no email",
              !fixtureLine.lowercased().contains("token")
              && !fixtureLine.contains("@")
              && !fixtureLine.lowercased().contains("bearer"),
              fixtureLine)

        let nullLine = UsageLog.line(label: "C", snapshot: decodedNull ?? UsageSnapshot())
        let zeroLine = UsageLog.line(label: "C", snapshot: decodedZero ?? UsageSnapshot())
        check("a null reading logs as null", nullLine.contains("5-hour=null/no-window"), nullLine)
        check("a reported zero logs as 0", zeroLine.contains("5-hour=0/no-window"), zeroLine)
        check("the two payloads log differently — the whole point", nullLine != zeroLine)
        check("a bucket that never arrived logs as absent",
              nullLine.contains("weekly=absent") && nullLine.contains("scoped=none"),
              nullLine)
        check("no reading at all logs headroom=none, a full one logs a number",
              nullLine.contains("headroom=none") && zeroLine.contains("headroom=100"),
              zeroLine)
        // Flat top-level keys instead of `limits[]` is itself a payload shape
        // worth knowing about after the fact.
        let flatLine = UsageLog.line(
            label: "C",
            snapshot: (try? UsageDecoder.decode(Data(
                #"{"five_hour":{"utilization":5,"resets_at":null}}"#.utf8
            ))) ?? UsageSnapshot()
        )
        check("a flat-key payload says so in the line",
              flatLine.contains("kinds=none") && flatLine.contains("flat-keys"),
              flatLine)

        // MARK: Fable exhaustion
        //
        // Exhausted means the Fable bucket is *there* and has used everything.
        // The API nulls these keys routinely, so an absent bucket says nothing
        // about Fable at all — treating "unknown" as "spent" would turn a quiet
        // week yellow and quietly stop measuring Fable for accounts that still
        // have it.

        /// `percent: nil` is the bucket the server sent with nothing in it.
        func fableBucket(_ percent: Double?, reported: Bool = true) -> UsageBucket {
            UsageBucket(
                id: "scoped:Fable", label: "Fable", percent: percent,
                resetsAt: reported ? Date() : nil
            )
        }
        func snapshot(five: Double = 30, weekly: Double = 20, fable: UsageBucket?) -> UsageSnapshot {
            var out = UsageSnapshot()
            out.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: five, resetsAt: Date())
            out.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: weekly, resetsAt: Date())
            if let fable { out.scoped = [fable] }
            return out
        }

        let fableSpent = snapshot(fable: fableBucket(100))
        let fablePartial = snapshot(fable: fableBucket(25))
        let fableSentinel = snapshot(fable: fableBucket(nil, reported: false))
        let fableMissing = snapshot(fable: nil)

        check("Fable present and at 100% is exhausted", fableSpent.isFableExhausted)
        check("a partly used Fable is not exhausted", !fablePartial.isFableExhausted)
        check("a Fable just short of 100% is not exhausted",
              !snapshot(fable: fableBucket(99.5)).isFableExhausted)
        check("an unreported Fable is unknown, not exhausted", !fableSentinel.isFableExhausted)
        check("a missing Fable bucket is unknown, not exhausted", !fableMissing.isFableExhausted)
        check("a snapshot with nothing in it is not exhausted", !UsageSnapshot().isFableExhausted)
        check("the live fixture's 25% Fable is not exhausted", !snap.isFableExhausted)
        // A real zero is present, so it is a constraint of 100% headroom, and
        // nowhere near exhausted — with or without an open window, since a
        // window that has not started is exactly what an untouched one looks
        // like.
        check("a reported, unused Fable is present and not exhausted",
              snapshot(fable: fableBucket(0)).isFableExhausted == false
              && snapshot(fable: fableBucket(0)).fable?.hasData == true)
        check("…and so is one reported as zero with no window yet",
              snapshot(fable: fableBucket(0, reported: false)).fable?.hasData == true
              && snapshot(fable: fableBucket(0, reported: false)).headroom == 70)

        // What the gauge then measures.
        check("an exhausted Fable drops out of the minimum",
              fableSpent.headroom == 70, "got \(fableSpent.headroom.map { String($0) } ?? "nil")")
        check("a live Fable is still the tightest window it can be",
              snapshot(fable: fableBucket(95)).headroom == 5,
              "got \(snapshot(fable: fableBucket(95)).headroom.map { String($0) } ?? "nil")")
        check("a partly used Fable stays in the minimum",
              fablePartial.headroom == 70 && snapshot(fable: fableBucket(90)).headroom == 10)
        check("an unreported Fable is skipped without counting as exhaustion",
              fableSentinel.headroom == 70 && fableMissing.headroom == 70)
        // Dropping Fable is not a reprieve: the windows that are left still say
        // what they say.
        let spentAndBlocked = snapshot(five: 100, weekly: 45, fable: fableBucket(100))
        check("an exhausted Fable cannot unblock a spent session",
              spentAndBlocked.headroom == 0 && spentAndBlocked.isFableExhausted)
        var onlyFable = UsageSnapshot()
        onlyFable.scoped = [fableBucket(100)]
        check("an exhausted Fable with nothing else reported measures nothing",
              onlyFable.headroom == nil && onlyFable.isFableExhausted)

        // The popover reads the same number the gauge does, so an account with
        // Fable gone and a whole session in hand must not say "Blocked".
        let spentState = AccountState(snapshot: fableSpent, error: nil)
        check("the verdict follows the effective headroom",
              Verdict.word(headroom: spentState.snapshot?.headroom) == "Available",
              "got \(Verdict.word(headroom: spentState.snapshot?.headroom))")
        check("…and still says Blocked when the rest is genuinely spent",
              Verdict.word(headroom: spentAndBlocked.headroom) == "Blocked")
        check("…while a Fable that is nearly, but not, spent still sets the word",
              Verdict.word(headroom: fablePartial.headroom) == "Available"
              && Verdict.word(headroom: snapshot(fable: fableBucket(96)).headroom) == "Almost out")
        // The row itself still reads as exhausted — 100%, with its window.
        check("the exhausted Fable row prints 100%",
              MetricDisplay.percentText(fableSpent.fable) == "100%"
              && MetricDisplay.resetText(fableSpent.fable) != "—")

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
              BarRenderer.glyphColor(colored: true) == .labelColor
              && BarRenderer.glyphColor(colored: true) != .systemRed
              && BarRenderer.glyphColor(colored: true) != .systemOrange)
        check("letters follow the menu bar's own label colour",
              BarRenderer.glyphColor(colored: true)
              == BarRenderer.neutralColor(colored: true))

        // …and that colour has to be resolved against the menu bar, not baked
        // in. Hard white would vanish on a light menu bar, so the letters are
        // checked in both appearances rather than in whichever one is on now.
        func glyphBrightness(_ name: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                value = BarRenderer.glyphColor(colored: true)
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

        // The letter's colour says *which* limit is being measured, and it only
        // has that to say while a limit is left: yellow points at the windows
        // the gauge switched to, so an account with nothing in those windows
        // either has no yellow to show — it goes back to the plain dimmed
        // letter that every blocked account wears.
        // Resolved against a real appearance, because a dynamic colour says
        // nothing until it is — and the menu bar's own appearance follows the
        // desktop picture, so both cases happen on the same machine.
        func rgb(_ color: NSColor, in name: NSAppearance.Name) -> (r: Double, g: Double, b: Double) {
            var out = (r: -1.0, g: -1.0, b: -1.0)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                if let resolved = color.usingColorSpace(.sRGB) {
                    out = (Double(resolved.redComponent),
                           Double(resolved.greenComponent),
                           Double(resolved.blueComponent))
                }
            }
            return out
        }
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func linear(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
        }
        /// The glyph composited onto the bar it is drawn on, measured against
        /// that bar. `bar` is the same backdrop `--render` paints.
        func contrast(_ ink: NSColor, alpha: Double, in name: NSAppearance.Name) -> Double {
            let bar = name == .darkAqua ? 0.12 : 0.94
            let c = rgb(ink, in: name)
            let composited = (r: alpha * c.r + (1 - alpha) * bar,
                              g: alpha * c.g + (1 - alpha) * bar,
                              b: alpha * c.b + (1 - alpha) * bar)
            let a = luminance(composited) + 0.05
            let b = luminance((bar, bar, bar)) + 0.05
            return max(a, b) / min(a, b)
        }
        func separation(_ one: NSColor, _ other: NSColor, in name: NSAppearance.Name) -> Double {
            let a = rgb(one, in: name), b = rgb(other, in: name)
            return max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        }

        let yellowInk = BarRenderer.glyphColor(colored: true, fableExhausted: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let ink = rgb(yellowInk, in: appearance)
            check("the Fable-exhausted letter reads as yellow on \(appearance.rawValue)",
                  ink.r > ink.g && ink.g > ink.b && ink.b < 0.15 && ink.g > 0.5 * ink.r,
                  "rgb \(ink)")
        }
        check("on a dark menu bar it is systemYellow itself",
              rgb(yellowInk, in: .darkAqua) == rgb(.systemYellow, in: .darkAqua),
              "got \(rgb(yellowInk, in: .darkAqua))")
        check("…and an ordinary letter is not yellow at all",
              rgb(BarRenderer.glyphColor(colored: true), in: .darkAqua)
              != rgb(yellowInk, in: .darkAqua))
        // Legibility, measured rather than eyeballed. Plain systemYellow on a
        // light menu bar is 1.3:1 — which is why the ink darkens there.
        check("the yellow letter is legible on a dark menu bar",
              contrast(yellowInk, alpha: 1, in: .darkAqua) >= 3.5,
              String(format: "%.2f:1", contrast(yellowInk, alpha: 1, in: .darkAqua)))
        check("…and on a light one",
              contrast(yellowInk, alpha: 1, in: .aqua) >= 3.5,
              String(format: "%.2f:1", contrast(yellowInk, alpha: 1, in: .aqua)))
        check("plain systemYellow would have vanished on a light menu bar",
              contrast(.systemYellow, alpha: 1, in: .aqua) < 1.5,
              String(format: "%.2f:1", contrast(NSColor.systemYellow, alpha: 1, in: .aqua)))
        // Full strength is the only legibility yellow has to hold, because the
        // one state that would have dimmed it is the one state that no longer
        // takes it — see the four-way rule below.
        // The letter's yellow and the gauge's orange are two different signals
        // sitting a couple of points apart, so they have to be two different
        // colours — in whichever appearance the menu bar happens to be in.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            check("yellow is nothing like the gauge's orange on \(appearance.rawValue)",
                  separation(yellowInk, .systemOrange, in: appearance) > 0.15,
                  String(format: "%.2f apart", separation(yellowInk, .systemOrange, in: appearance)))
            check("…nor like its red on \(appearance.rawValue)",
                  separation(yellowInk, .systemRed, in: appearance) > 0.15,
                  String(format: "%.2f apart", separation(yellowInk, .systemRed, in: appearance)))
        }
        check("the gauge keeps its own tiers and never goes yellow",
              BarRenderer.warningColor(for: 20) == .systemOrange
              && BarRenderer.warningColor(for: 5) == .systemRed
              && BarRenderer.warningColor(for: 70) == nil)
        // The four-way rule the letter follows. Yellow is a *redirection* —
        // "Fable is gone, the gauge is measuring what's left" — so it lasts
        // exactly as long as there is something left to redirect to. Once the
        // effective headroom is 0 the account is simply blocked, and blocked has
        // one look: dimmed label ink, the same as it wore before yellow existed.
        let dim = BarRenderer.blockedGlyphAlpha
        func letterInk(_ headroom: Double?, fableExhausted: Bool) -> NSColor {
            BarRenderer.glyphColor(
                colored: true, fableExhausted: fableExhausted, headroom: headroom
            )
        }
        func fableCellImage(_ headroom: Double?, exhausted: Bool) -> NSImage {
            BarRenderer.image(for: [
                BarCell(character: "E", headroom: headroom,
                        isUnreachable: false, isFableExhausted: exhausted)
            ])
        }
        check("Fable spent with room left is yellow, full strength",
              letterInk(70, fableExhausted: true) === BarRenderer.fableYellow
              && BarRenderer.glyphAlpha(headroom: 70) == 1)
        check("Fable spent and fully blocked is label ink, dimmed — no yellow",
              letterInk(0, fableExhausted: true) == .labelColor
              && letterInk(0, fableExhausted: true) !== BarRenderer.fableYellow
              && BarRenderer.glyphAlpha(headroom: 0) == dim,
              "got \(letterInk(0, fableExhausted: true))")
        check("blocked without Fable exhaustion is that same dimmed label ink",
              letterInk(0, fableExhausted: false) == .labelColor
              && letterInk(0, fableExhausted: false) == letterInk(0, fableExhausted: true)
              && BarRenderer.glyphAlpha(headroom: 0) == dim)
        check("everything else is label ink at full strength",
              letterInk(70, fableExhausted: false) == .labelColor
              && BarRenderer.glyphAlpha(headroom: 70) == 1)
        check("the two blocked cases are indistinguishable in the cluster too",
              fableCellImage(0, exhausted: true).tiffRepresentation
              == fableCellImage(0, exhausted: false).tiffRepresentation)
        // Driven through the snapshots that produce the numbers, because it is
        // the *effective* headroom the rule turns on — the one the gauge draws
        // and the popover's verdict already reads.
        check("a spent Fable over a spent session takes the blocked letter",
              spentAndBlocked.headroom == 0 && spentAndBlocked.isFableExhausted
              && letterInk(spentAndBlocked.headroom, fableExhausted: true) == .labelColor)
        check("…while the same spent Fable over a live session stays yellow",
              fableSpent.headroom == 70
              && letterInk(fableSpent.headroom, fableExhausted: true)
              === BarRenderer.fableYellow)
        // A reading that never arrived is not a blocked one. Nothing has said
        // the remaining windows are spent, so the redirection still stands.
        check("a spent Fable with no other reading at all keeps its yellow",
              onlyFable.headroom == nil
              && letterInk(onlyFable.headroom, fableExhausted: true) === BarRenderer.fableYellow)
        // Template mode is the menu bar's own treatment — the system tints and
        // inverts the image with everything else up there — so leaving it has to
        // buy something. Real ink on the page buys it; a colour tier nothing is
        // drawn in does not. So the test is exactly "is any colour laid down".
        let yellowCluster = [
            BarCell(character: "Y", headroom: 70, isUnreachable: false, isFableExhausted: true)
        ]
        let plainCluster = [BarCell(character: "Y", headroom: 70, isUnreachable: false)]
        let blockedYellowCluster = [
            BarCell(character: "B", headroom: 0, isUnreachable: false, isFableExhausted: true)
        ]
        let blockedCluster = [BarCell(character: "B", headroom: 0, isUnreachable: false)]
        let warningCluster = [BarCell(character: "W", headroom: 8, isUnreachable: false)]
        check("a Fable-exhausted cell forces real colour",
              BarRenderer.forcesColor(yellowCluster)
              && BarRenderer.image(for: yellowCluster).isTemplate == false)
        check("…while an ordinary healthy cluster stays a template",
              !BarRenderer.forcesColor(plainCluster)
              && BarRenderer.image(for: plainCluster).isTemplate)
        check("a fully blocked Fable-exhausted cluster goes back to a template",
              !BarRenderer.forcesColor(blockedYellowCluster)
              && BarRenderer.image(for: blockedYellowCluster).isTemplate)
        check("…and so does a plain blocked one, whose red is never painted",
              !BarRenderer.forcesColor(blockedCluster)
              && BarRenderer.image(for: blockedCluster).isTemplate
              && BarRenderer.levelColor(for: blockedCluster[0]) == nil
              && BarRenderer.warningColor(for: 0) == .systemRed)
        check("a painted warning level still forces colour",
              BarRenderer.levelColor(for: warningCluster[0]) == .systemRed
              && BarRenderer.forcesColor(warningCluster)
              && BarRenderer.image(for: warningCluster).isTemplate == false)
        // And one blocked account among live ones changes nothing about it: the
        // cluster is coloured by its neighbour, and the blocked letter is the
        // label ink that colouring makes available, still dimmed.
        check("a blocked cell alongside a yellow one is still not yellow itself",
              BarRenderer.forcesColor(blockedYellowCluster + yellowCluster)
              && letterInk(0, fableExhausted: true) == .labelColor)
        check("a yellow letter draws differently from the same reading in white",
              fableCellImage(70, exhausted: true).tiffRepresentation
              != fableCellImage(70, exhausted: false).tiffRepresentation)
        check("a blocked letter draws differently from a full-strength yellow",
              fableCellImage(0, exhausted: true).tiffRepresentation
              != fableCellImage(70, exhausted: true).tiffRepresentation)
        // The status item only redraws when the cluster changes, so the flip in
        // and out of exhaustion has to be part of what "changed" means.
        check("flipping to Fable-exhausted changes the cell",
              BarCell(character: "F", headroom: 70, isUnreachable: false, isFableExhausted: true)
              != BarCell(character: "F", headroom: 70, isUnreachable: false))
        check("…and flipping back restores the original cell",
              BarCell(character: "F", headroom: 70, isUnreachable: false, isFableExhausted: false)
              == BarCell(character: "F", headroom: 70, isUnreachable: false))

        // Hollow means "no data", painted-but-empty means "the data says zero".
        // The two must therefore never render identically.
        func cell(_ headroom: Double?, unreachable: Bool) -> NSImage {
            BarRenderer.image(for: [
                BarCell(character: "E", headroom: headroom, isUnreachable: unreachable)
            ])
        }
        func cellsFor(_ specs: [(Double?, Bool)]) -> [BarCell] {
            specs.map { BarCell(character: "E", headroom: $0.0, isUnreachable: $0.1) }
        }
        check("unreachable outlines, healthy zero does not",
              cell(nil, unreachable: true).tiffRepresentation
              != cell(0, unreachable: false).tiffRepresentation)

        // MARK: The track grammar
        //
        // Two axes, two marks. The track says whether there is a live reading;
        // the level says how much of it is left:
        //
        //     painted + level  live data
        //     painted + empty  blocked, and the server said so
        //     outline + level  stale — the last reading, no longer refreshing
        //     outline + empty  no reading
        //
        // No-reading used to fall on the *painted* side, because the predicate
        // asked only whether the connection had failed. A fetch that succeeds
        // and measures nothing has no error, so it drew a painted empty track —
        // separated from blocked by nothing but the letter's alpha, and those
        // are the two states most worth keeping apart. The predicate now asks
        // about the data too, so the difference is the whole track.
        check("no reading outlines even when the fetch worked",
              BarCell(character: "E", headroom: nil, isUnreachable: false).isOutlined)
        check("a failed fetch outlines whatever it last knew",
              BarCell(character: "E", headroom: 60, isUnreachable: true).isOutlined)
        check("blocked stays painted — the server said zero",
              !BarCell(character: "E", headroom: 0, isUnreachable: false).isOutlined)
        check("live data stays painted",
              !BarCell(character: "E", headroom: 60, isUnreachable: false).isOutlined)
        // And it is the drawing that has to differ, not just the predicate.
        check("no-reading and blocked are now different pictures",
              cell(nil, unreachable: false).tiffRepresentation
              != cell(0, unreachable: false).tiffRepresentation)
        check("…and no reading draws the same however it came about",
              cell(nil, unreachable: false).tiffRepresentation
              == cell(nil, unreachable: true).tiffRepresentation)
        // The residual case must not disturb the normal ones: an account with a
        // reading draws exactly as it did before.
        check("a normal account is unaffected by the new predicate",
              !BarCell(character: "E", headroom: 85, isUnreachable: false).isOutlined
              && !BarCell(character: "E", headroom: 1, isUnreachable: false).isOutlined
              && !BarCell(character: "E", headroom: 100, isUnreachable: false).isOutlined)
        // And a rate limited account keeps drawing the level it last knew,
        // which is the whole point of holding onto the snapshot.
        check("a stale reading is still drawn inside the hollow track",
              cell(60, unreachable: true).tiffRepresentation
              != cell(nil, unreachable: true).tiffRepresentation)
        // The status item redraws only when the cluster actually changed, so the
        // cells have to compare equal for equal inputs — otherwise every state
        // change reassigns the image, and reassigning the image is what makes
        // the status item re-snapshot itself.
        check("identical readings produce identical cells",
              cellsFor([(nil, false), (60, true), (0, false)])
              == cellsFor([(nil, false), (60, true), (0, false)]))
        check("a changed reading produces different cells",
              cellsFor([(60, false)]) != cellsFor([(61, false)]))
        // And the image resolves its colours at draw time rather than baking
        // them in. That is what removed the need to watch the button's
        // appearance — and watching it was a self-feeding redraw loop that cost
        // a permanent CPU core.
        check("the menu bar image is never cached",
              cell(60, unreachable: false).cacheMode == .never,
              "got \(cell(60, unreachable: false).cacheMode.rawValue)")

        check("verdicts", Verdict.word(headroom: 85) == "Available"
            && Verdict.word(headroom: 30) == "Limited"
            && Verdict.word(headroom: 8) == "Almost out"
            && Verdict.word(headroom: 0) == "Blocked")

        // Account defaults derive from the email's local part.
        let account = Account(email: "izu@personal.com", refreshToken: "x")
        check("default nickname", account.nickname == "Izu", "got \(account.nickname)")
        check("default label", account.label == "I", "got \(account.label)")
        check("label normalizes", Account.normalizeLabel(" work ") == "W")

        // MARK: What a row prints
        //
        // The row and the verdict have to agree. Three rows saying "you have
        // used nothing" under a verdict saying "No data" is the app
        // contradicting itself, and it is only avoidable because the null and
        // the zero are still distinguishable this far down.
        let noReading = UsageBucket(id: "x", label: "x", percent: nil, resetsAt: nil)
        check("a bucket with no reading has no data", noReading.hasData == false)
        let realZero = UsageBucket(id: "y", label: "y", percent: 0, resetsAt: Date())
        check("zero with reset is present", realZero.hasData == true)

        check("a row with no reading prints a dash, not 0%",
              MetricDisplay.percentText(noReading) == "—",
              "got \(MetricDisplay.percentText(noReading))")
        check("…and a dash in its reset column too, so the row reads as one gap",
              MetricDisplay.resetText(noReading) == "—",
              "got \(MetricDisplay.resetText(noReading))")
        check("a missing bucket prints two dashes",
              MetricDisplay.percentText(nil) == "—" && MetricDisplay.resetText(nil) == "—")
        check("a reported zero still prints 0% — the user asked for that",
              MetricDisplay.percentText(realZero) == "0%"
              && MetricDisplay.resetText(realZero) != "—")
        let zeroNoWindow = UsageBucket(id: "y2", label: "y2", percent: 0, resetsAt: nil)
        check("…including a zero with no window yet: 0% and a dash",
              MetricDisplay.percentText(zeroNoWindow) == "0%"
              && MetricDisplay.resetText(zeroNoWindow) == "—")
        check("a reported zero and no reading never print alike",
              MetricDisplay.percentText(zeroNoWindow) != MetricDisplay.percentText(noReading))
        let full = UsageBucket(id: "z", label: "z", percent: 100, resetsAt: Date())
        check("100 prints 100%", MetricDisplay.percentText(full) == "100%",
              "got \(MetricDisplay.percentText(full))")
        check("percents round rather than truncate",
              MetricDisplay.percentText(
                  UsageBucket(id: "r", label: "r", percent: 99.6, resetsAt: Date())
              ) == "100%")

        // Display and maths read the same bit, so they cannot disagree: a bucket
        // with no reading is skipped by the headroom *and* dashed on screen,
        // while a reported zero counts as a whole window *and* prints 0%.
        var displayVsMaths = UsageSnapshot()
        displayVsMaths.fiveHour = UsageBucket(
            id: "session", label: "5-hour", percent: nil, resetsAt: nil
        )
        displayVsMaths.weekly = UsageBucket(
            id: "weekly", label: "Weekly", percent: 40, resetsAt: Date()
        )
        check("a dashed row is the row headroom skipped",
              displayVsMaths.headroom == 60
              && MetricDisplay.percentText(displayVsMaths.fiveHour) == "—",
              "got \(reading(displayVsMaths.headroom))")
        displayVsMaths.fiveHour = UsageBucket(
            id: "session", label: "5-hour", percent: 0, resetsAt: nil
        )
        check("…and a 0% row is a row headroom counted",
              displayVsMaths.headroom == 60
              && MetricDisplay.percentText(displayVsMaths.fiveHour) == "0%",
              "got \(reading(displayVsMaths.headroom))")

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
        // The loop's only pause. At zero it stops being a poll loop and becomes
        // a spin, so the wait is asserted rather than assumed — a whole CPU core
        // is what the alternative costs.
        check("the loop always waits between ticks", PollPolicy.tick > 0)
        check("…and its sleep can never round down to nothing",
              PollPolicy.tickNanoseconds >= 1_000_000_000,
              "\(PollPolicy.tickNanoseconds)ns")
        check("the sleep matches the tick it is derived from",
              PollPolicy.tickNanoseconds == UInt64(PollPolicy.tick * 1_000_000_000))
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

        // Offline: the request never leaves the machine, so it costs the API
        // nothing and the ladder is allowed to stay tight — 15s, 30s, then a
        // minute for as long as the outage lasts. Anything looser and the app
        // stops recovering by itself when the Wi-Fi comes back.
        let offline = (1...6).map { Backoff.delay(failures: $0, kind: .offline) }
        check("offline retries at 15s, 30s, then a flat minute",
              offline == [15, 30, 60, 60, 60, 60], "got \(offline.map { Int($0) })")
        check("the offline ladder caps at a minute",
              Backoff.Failure.offline.cap == 60
              && Backoff.delay(failures: 500, kind: .offline) == 60)
        check("offline starts tighter than every other failure",
              Backoff.Failure.offline.base < Backoff.Failure.transient.base
              && Backoff.Failure.offline.base < Backoff.Failure.rateLimited.base)
        check("…and never climbs above where transient starts",
              offline.allSatisfy { $0 <= Backoff.Failure.transient.base })
        check("an hour offline is still a retry a minute, not a latch",
              Backoff.delay(failures: 60, kind: .offline) == 60)
        // The one ladder that must not have moved.
        check("the 429 ladder is untouched by any of this",
              (1...6).map { Backoff.delay(failures: $0, kind: .rateLimited) }
              == [300, 600, 1200, 2400, 2700, 2700])

        // Which errors count as offline, and what they say on screen.
        let offlineErrors: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed
        ]
        check("every offline URLError is recognised as one",
              offlineErrors.allSatisfy { NetworkFailure.isOffline(URLError($0)) },
              "\(offlineErrors.filter { !NetworkFailure.isOffline(URLError($0)) })")
        check("a timeout is not offline — the request did leave",
              !NetworkFailure.isOffline(URLError(.timedOut))
              && !NetworkFailure.isOffline(URLError(.badServerResponse)))
        // URLSession hands these back as an `NSError` in `NSURLErrorDomain`;
        // only the bridge makes them a `URLError`. If that bridge ever stopped
        // working the mapping would silently fall through to Foundation's own
        // sentence, which is precisely the string this replaced.
        check("an offline failure arriving as a bridged NSError still classifies",
              NetworkFailure.isOffline(
                  NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
              ))
        check("nor is anything that isn't a URLError",
              !NetworkFailure.isOffline(UsageError.http(503))
              && !NetworkFailure.isOffline(OAuthError.timedOut))
        check("offline reads as 'No Internet', not as Foundation's sentence",
              offlineErrors.allSatisfy {
                  AppState.outcome(for: URLError($0)).message == "No Internet"
              },
              "got \(AppState.outcome(for: URLError(.notConnectedToInternet)).message ?? "nil")")
        check("…and is short enough to sit in the verdict column unclipped",
              NetworkFailure.offlineText.count <= 12,
              NetworkFailure.offlineText)
        check("offline lands on the offline ladder, not the transient one",
              AppState.outcome(for: URLError(.notConnectedToInternet)).failureKind == .offline)
        check("a timeout still lands on the transient ladder",
              AppState.outcome(for: URLError(.timedOut)).failureKind == .transient)
        check("a 429 still lands on the rate-limited ladder",
              AppState.outcome(for: UsageError.rateLimited(retryAfter: nil)).failureKind
              == .rateLimited)
        check("offline is never mistaken for a dead credential",
              !AppState.outcome(for: URLError(.notConnectedToInternet)).isNeedsSignIn)

        // A timeout used to reach the popover as Foundation wrote it — "The
        // request timed out." — which is a sentence, in a column sized for a
        // word. Same treatment as offline, same single source.
        check("a timeout reads as 'Timed out', not as Foundation's sentence",
              AppState.outcome(for: URLError(.timedOut)).message == "Timed out",
              "got \(AppState.outcome(for: URLError(.timedOut)).message ?? "nil")")
        check("…and fits the verdict column like the offline word does",
              NetworkFailure.timedOutText.count <= 12, NetworkFailure.timedOutText)
        check("…and says something different from an outage",
              NetworkFailure.timedOutText != NetworkFailure.offlineText)
        check("a bridged NSError timeout gets the same word",
              AppState.outcome(
                  for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
              ).message == "Timed out")

        // The general leak, closed at the source rather than case by case. Every
        // one of these has a Foundation string, and not one of them may reach
        // the screen. `.badServerResponse` is the sharp one: Foundation has no
        // sentence for it at all and returns "The operation couldn't be
        // completed. (NSURLErrorDomain error -1011.)".
        let leakyCodes: [URLError.Code] = [
            .timedOut, .badServerResponse, .cannotParseResponse,
            .secureConnectionFailed, .serverCertificateUntrusted,
            .resourceUnavailable, .unknown, .badURL, .cancelled
        ]
        let leaked = leakyCodes.filter { code in
            let message = AppState.outcome(for: URLError(code)).message ?? ""
            return message != NetworkFailure.offlineText
                && message != NetworkFailure.timedOutText
                && message != NetworkFailure.genericText
        }
        check("no URLError reaches the verdict in Foundation's words",
              leaked.isEmpty, "leaked \(leaked)")
        check("…including the codes Foundation has no sentence for",
              AppState.outcome(for: URLError(.badServerResponse)).message
              == NetworkFailure.genericText)
        check("…and an error from no domain this app knows at all",
              AppState.outcome(
                  for: NSError(domain: "com.example.whatever", code: 42)
              ).message == NetworkFailure.genericText)
        check("every verdict string is a word, not a sentence",
              [NetworkFailure.offlineText, NetworkFailure.timedOutText,
               NetworkFailure.genericText].allSatisfy {
                  $0.count <= 14 && !$0.hasSuffix(".")
              })
        // The named errors still say the specific thing they always said — the
        // generic word is a floor under the unrecognised, not a replacement for
        // what this app actually knows.
        check("a known HTTP failure keeps its own words",
              AppState.outcome(for: UsageError.http(503)).message == "HTTP 503")
        check("a 429 keeps its own words",
              AppState.outcome(for: UsageError.rateLimited(retryAfter: nil)).message
              == "rate limited")
        check("an OAuth failure keeps its own words",
              AppState.outcome(for: OAuthError.refreshBusy).message == "busy")

        // Which ladder a timeout belongs on. It is *not* the offline one: the
        // request left this machine and the server may have received it, so the
        // 15-second cadence that offline earns by costing the API nothing is
        // exactly wrong here.
        check("a timeout stays on the transient ladder, not the offline one",
              AppState.outcome(for: URLError(.timedOut)).failureKind == .transient)
        check("…so its first retry is a minute, not fifteen seconds",
              Backoff.delay(failures: 1, kind: .transient) == 60)
        check("…and it never retries faster than the offline ladder would",
              (1...6).allSatisfy {
                  Backoff.delay(failures: $0, kind: .transient)
                  >= Backoff.delay(failures: $0, kind: .offline)
              })
        check("an unrecognised failure also stays transient",
              AppState.outcome(for: URLError(.badServerResponse)).failureKind == .transient
              && AppState.outcome(
                  for: NSError(domain: "com.example.whatever", code: 42)
              ).failureKind == .transient)
        check("no new wording moved the 429 ladder",
              (1...6).map { Backoff.delay(failures: $0, kind: .rateLimited) }
              == [300, 600, 1200, 2400, 2700, 2700])

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

        // The offline schedule, end to end: three failures in and it is still
        // asking again inside a minute, and one success wipes it.
        var outage = RetrySchedule()
        check("a fresh schedule is not an offline one", !outage.isOffline)
        for _ in 0..<3 { outage.recordFailure(.offline, now: epoch) { _ in 0 } }
        check("three offline failures still retry within the minute",
              outage.blockedUntil == epoch.addingTimeInterval(60),
              "blocked until \(outage.blockedUntil.map { "\($0)" } ?? "nil")")
        check("…and the schedule knows why it is waiting", outage.isOffline)
        outage.recordSuccess()
        check("the network coming back clears the offline schedule outright",
              !outage.isOffline && outage.failures == 0 && outage.blockedUntil == nil)
        // Going offline mid-429 must not walk the rate-limit ladder back down.
        var mixed = RetrySchedule()
        for _ in 0..<3 { mixed.recordFailure(.rateLimited, now: epoch) { _ in 0 } }
        mixed.recordFailure(.offline, now: epoch) { _ in 0 }
        mixed.recordFailure(.rateLimited, now: epoch) { _ in 0 }
        check("an outage cannot be used to reset the 429 ladder",
              mixed.failures == 5 && !mixed.isOffline
              && mixed.blockedUntil == epoch.addingTimeInterval(2700),
              "failures \(mixed.failures)")

        // Every failure has to push the next attempt *strictly* into the future.
        // A schedule that ever hands back "now" leaves the account due on the
        // very next tick, for ever, which is a poll loop with the brakes off.
        var futureFailures: [String] = []
        for kind in [Backoff.Failure.rateLimited, .transient, .offline] {
            for failures in 1...24 {
                for roll in [{ (r: ClosedRange<Double>) in r.lowerBound },
                             { (r: ClosedRange<Double>) in r.upperBound },
                             { (r: ClosedRange<Double>) in Double.random(in: r) }] {
                    let next = Backoff.nextAttempt(
                        failures: failures, kind: kind, now: epoch, roll: roll
                    )
                    if next <= epoch { futureFailures.append("\(kind) x\(failures)") }
                }
            }
        }
        check("every rung of the ladder lands strictly in the future",
              futureFailures.isEmpty, futureFailures.first ?? "")
        // Including when the server's own Retry-After is zero, negative or long
        // expired — a `Retry-After: 0` must not become "due immediately".
        let zeroAfter = Backoff.nextAttempt(
            failures: 1, kind: .rateLimited, retryAfter: epoch, now: epoch
        )
        check("a Retry-After of now is still pushed out a full interval",
              zeroAfter == epoch.addingTimeInterval(PollPolicy.interval))
        check("an expired Retry-After is too",
              Backoff.nextAttempt(
                  failures: 1, kind: .rateLimited,
                  retryAfter: epoch.addingTimeInterval(-86_400), now: epoch
              ) == epoch.addingTimeInterval(PollPolicy.interval))
        // And the schedule a failure writes must actually block at that instant.
        var blockChecks: [String] = []
        for failures in 1...24 {
            var s = RetrySchedule()
            for _ in 0..<failures { s.recordFailure(.transient, now: epoch) }
            guard let until = s.blockedUntil, until > epoch, s.isBlocked(at: epoch) else {
                blockChecks.append("x\(failures)")
                continue
            }
        }
        check("a failed account is blocked the moment it fails, at every depth",
              blockChecks.isEmpty, blockChecks.first ?? "")

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

        // MARK: A failure neither clears a reading nor invents one
        //
        // Driven through `AccountState.applying`, which is the transition the
        // app itself runs — not a restatement of it — so these cannot pass while
        // `fetch` does something else.

        func plainBucket(_ id: String, _ label: String, _ percent: Double?) -> UsageBucket {
            UsageBucket(id: id, label: label, percent: percent, resetsAt: nil)
        }
        func triple(_ percent: Double?) -> UsageSnapshot {
            var out = UsageSnapshot()
            out.fiveHour = plainBucket("session", "5-hour", percent)
            out.weekly = plainBucket("weekly", "Weekly", percent)
            out.scoped = [plainBucket("scoped:Fable", "Fable", percent)]
            return out
        }
        // The three real accounts, as the log shows them: two reporting a
        // genuine zero everywhere, one carrying live numbers.
        let reportedZeros = triple(0)
        let reportedNulls = triple(nil)
        let liveNumbers = snap

        let anyFailure = FetchOutcome.failure(
            message: "Timed out", kind: .transient, retryAfter: nil
        )

        // 1. It must not clear.
        let zerosAfter = AccountState.applying(anyFailure, to: AccountState(snapshot: reportedZeros))
        let liveAfter = AccountState.applying(anyFailure, to: AccountState(snapshot: liveNumbers))
        check("a failure leaves a zeros snapshot exactly where it was",
              zerosAfter.snapshot?.fiveHour?.percent == 0
              && zerosAfter.snapshot?.weekly?.percent == 0
              && zerosAfter.snapshot?.fable?.percent == 0)
        check("a failure leaves a live snapshot exactly where it was",
              liveAfter.snapshot?.headroom == 26,
              "got \(liveAfter.snapshot?.headroom.map { String($0) } ?? "nil")")
        check("…and both are marked stale rather than blank",
              zerosAfter.isStale && liveAfter.isStale)

        // 2. It must not synthesise. An account that has never loaded stays
        // empty — a failure cannot hand it a snapshot full of zeros, which is
        // now an assertion that the server measured nothing rather than a
        // neutral blank.
        let neverLoadedAfter = AccountState.applying(anyFailure, to: nil)
        check("a failure on an account that never loaded invents no snapshot",
              neverLoadedAfter.snapshot == nil)
        check("…so it reads as no data, not as a reported zero",
              !neverLoadedAfter.isStale && neverLoadedAfter.isUnreachable)
        check("a failure never manufactures a reading on an existing account",
              AppState.outcome(for: URLError(.timedOut)).snapshot == nil
              && AppState.outcome(for: UsageError.http(500)).snapshot == nil
              && AppState.outcome(for: URLError(.notConnectedToInternet)).snapshot == nil)

        // 3. The `0%` versus `—` distinction survives the failure. This is the
        // bit the optional `percent` bought, and a failure is exactly where it
        // would be cheapest to lose.
        let nullsAfter = AccountState.applying(anyFailure, to: AccountState(snapshot: reportedNulls))
        check("a reported zero still prints 0% after a failure",
              MetricDisplay.percentText(zerosAfter.snapshot?.fiveHour) == "0%",
              MetricDisplay.percentText(zerosAfter.snapshot?.fiveHour))
        check("a null reading still prints a dash after a failure",
              MetricDisplay.percentText(nullsAfter.snapshot?.fiveHour) == "—",
              MetricDisplay.percentText(nullsAfter.snapshot?.fiveHour))
        check("…and the two are still distinguishable while failing",
              MetricDisplay.percentText(zerosAfter.snapshot?.fiveHour)
              != MetricDisplay.percentText(nullsAfter.snapshot?.fiveHour))
        check("a failing zeros account still resolves full headroom, not none",
              zerosAfter.snapshot?.headroom == 100)
        check("a failing nulls account still resolves no headroom at all",
              nullsAfter.snapshot?.headroom == nil)

        // 4. Identical failure, identical behaviour — the actual complaint. The
        // three accounts differ only by what they were last told, never by how
        // the failure treated them.
        let cohort = [reportedZeros, reportedZeros, liveNumbers].map {
            AccountState.applying(anyFailure, to: AccountState(snapshot: $0))
        }
        check("every account under one failure keeps its snapshot",
              cohort.allSatisfy { $0.snapshot != nil })
        check("…carries the same verdict word",
              Set(cohort.map { $0.error ?? "" }) == ["Timed out"])
        check("…is stale rather than signed out",
              cohort.allSatisfy { $0.isStale && !$0.needsSignIn })
        check("…and is unreachable to exactly the same degree",
              Set(cohort.map(\.isUnreachable)) == [true])

        // 5. And the menu bar agrees. With an error on every account all three
        // gauges go hollow — but a retained reading still draws its level, which
        // is the grammar: outline says the reading is old, the level says what
        // it was. Only an account with nothing behind it draws hollow *and*
        // empty.
        let cohortCells = zip("PCI", cohort).map { character, state in
            BarCell(
                character: character,
                headroom: state.snapshot?.headroom,
                isUnreachable: state.isUnreachable,
                isFableExhausted: state.snapshot?.isFableExhausted == true
            )
        }
        check("all three gauges outline under one failure",
              cohortCells.allSatisfy(\.isOutlined))
        check("…and every one of them still draws a level",
              cohortCells.allSatisfy { $0.headroom != nil })
        check("…the zeros accounts full, the live one at what it last read",
              cohortCells.map(\.headroom) == [100, 100, 26],
              "got \(cohortCells.map { $0.headroom.map { Int($0) } })")
        check("outline plus level is the stale state, not the empty one",
              cohortCells.allSatisfy { $0.isOutlined && $0.headroom != nil }
              && BarRenderer.fillHeight(headroom: 100) > 0)
        let nothingEverLoaded = BarCell(
            character: "N", headroom: neverLoadedAfter.snapshot?.headroom,
            isUnreachable: neverLoadedAfter.isUnreachable
        )
        check("only an account with nothing behind it outlines with no level",
              nothingEverLoaded.isOutlined && nothingEverLoaded.headroom == nil)

        // 6. Success still overwrites, and still clears the verdict — the
        // retention above must not have turned into a latch.
        let recovered = AccountState.applying(.success(liveNumbers), to: zerosAfter)
        check("a success replaces the snapshot and clears the failure",
              recovered.snapshot?.headroom == 26 && recovered.error == nil
              && !recovered.isStale && !recovered.isUnreachable)
        let signedOut = AccountState.applying(.needsSignIn, to: liveAfter)
        check("a dead credential clears the failure word and keeps no error",
              signedOut.needsSignIn && signedOut.error == nil)

        // The failure log line — the thing whose absence made this bug readable
        // only from a screenshot.
        let failLine = UsageLog.failureLine(
            label: "P", message: "Timed out", kind: .transient, attempt: 2
        )
        check("a failed poll logs which account, verdict, ladder and depth",
              failLine.contains("[P]") && failLine.contains("verdict=Timed out")
              && failLine.contains("ladder=transient") && failLine.contains("attempt=2"),
              failLine)
        check("the failure line is one line and carries no credential or email",
              !failLine.contains("\n") && !failLine.contains("@"), failLine)

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

        // MARK: The store did not move
        //
        // The app is called Fablemeter now; its storage directory is still
        // `ClaudeUsageBar`, and deliberately so — the path is invisible to the
        // user, and the accounts sitting in it are the only copy of their
        // refresh tokens, which are single-use and rotate. A rename here would
        // be a migration with nothing to gain and orphaned accounts to lose, so
        // these two checks are the ones that fail if anyone ever tries it
        // without writing one.
        Store.directoryOverride = nil
        check("the store still lives in the ClaudeUsageBar directory",
              Store.directory.lastPathComponent == "ClaudeUsageBar",
              "got \(Store.directory.lastPathComponent)")
        check("…at Application Support/ClaudeUsageBar/accounts.json",
              Store.file.path.hasSuffix("Application Support/ClaudeUsageBar/accounts.json"),
              "got \(Store.file.path)")

        // The order has to survive the trip through disk, since that is the only
        // thing carrying it across a relaunch. Runs against a temporary
        // directory — shaped like the real one, so what is exercised is the path
        // an existing store actually sits at — so the user's own accounts.json
        // is never touched.
        let sandboxRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FablemeterSelfTest-\(UUID().uuidString)", isDirectory: true)
        let sandbox = sandboxRoot
            .appendingPathComponent("Library/Application Support/ClaudeUsageBar", isDirectory: true)
        Store.directoryOverride = sandbox
        // A store written before the rename is the same file the renamed app
        // opens: same directory name, same reader, same three accounts.
        try? Store.save(list)
        check("a store written under the old app name is still found",
              Store.load().map(\.id) == list.map(\.id)
              && Store.file.path.hasSuffix("Application Support/ClaudeUsageBar/accounts.json"),
              "got \(labels(Store.load()))")
        check("…with its labels and nicknames intact",
              Store.load().map(\.label) == ["P", "W", "T"]
              && Store.load().map(\.nickname) == ["Personal", "Work", "Team"])
        try? Store.save(list)
        check("store round-trips order", labels(Store.load()) == "PWT", "got \(labels(Store.load()))")
        if let reordered = AccountOrder.moved(list, id: t.id, onto: p.id) {
            try? Store.save(reordered)
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
        // A refresh token that rotated onto disk must survive every *other*
        // write the app makes. A rename or a reorder carrying an in-memory copy
        // of the old token used to stamp straight over it — which consumes the
        // token server-side and loses it, i.e. bricks the account.
        Store.directoryOverride = sandbox
        try? Store.save(list)
        try? Store.updateRefreshToken(id: w.id, to: "rotated-1")
        check("rotation lands on disk",
              Store.load().first { $0.id == w.id }?.refreshToken == "rotated-1")
        // `list` is the stale in-memory array, still holding "x" for w.
        try? Store.mutate { stored in
            stored = AccountOrder.sorted(stored, by: [t.id, p.id, w.id])
            if let i = stored.firstIndex(where: { $0.id == p.id }) { stored[i].nickname = "Renamed" }
        }
        let afterEdit = Store.load()
        check("a reorder + rename cannot undo a rotated token",
              afterEdit.first { $0.id == w.id }?.refreshToken == "rotated-1",
              "got \(afterEdit.first { $0.id == w.id }?.refreshToken.prefix(4).description ?? "nil")")
        check("…while the reorder and rename still applied",
              labels(afterEdit) == "TPW" && afterEdit.first { $0.id == p.id }?.nickname == "Renamed")
        // Compare-and-swap: a straggling refresh cannot stand on a token an
        // interactive sign-in has since written.
        try? Store.updateRefreshToken(id: w.id, to: "stale-rotation", replacing: "x")
        check("a rotation of a superseded token is refused",
              Store.load().first { $0.id == w.id }?.refreshToken == "rotated-1")
        try? Store.updateRefreshToken(id: w.id, to: "rotated-2", replacing: "rotated-1")
        check("a rotation of the current token is written",
              Store.load().first { $0.id == w.id }?.refreshToken == "rotated-2")
        let modeAfter = (try? FileManager.default.attributesOfItem(atPath: Store.file.path)[.posixPermissions])
            .flatMap { $0 as? NSNumber }?.intValue
        check("the durable write stays 0600", modeAfter == 0o600,
              "got \(modeAfter.map { String($0, radix: 8) } ?? "nil")")
        // A write that cannot land has to be an error, not a shrug: a rotated
        // token that never reached disk is a dead account.
        Store.directoryOverride = URL(fileURLWithPath: "/dev/null/nowhere")
        var surfaced = false
        do { try Store.save(list) } catch { surfaced = true }
        check("an impossible write throws rather than being swallowed", surfaced)
        Store.directoryOverride = sandbox

        try? FileManager.default.removeItem(at: sandboxRoot)
        Store.directoryOverride = nil
        check("selftest sandbox cleaned up", !FileManager.default.fileExists(atPath: sandboxRoot.path))

        // MARK: Token rotation
        //
        // Anthropic rotates the refresh token on every refresh: the old one is
        // consumed the instant the server answers, and presenting it again
        // returns 400 invalid_grant forever. Everything below exists because
        // both halves of that — refreshing twice at once, and returning before
        // the replacement is on disk — cost the user all three accounts.

        check("a 400 is a dead credential, not a blip",
              OAuthError.tokenExchange(400, #"{"error":"invalid_grant"}"#).isCredentialRejected)
        check("so is a 401", OAuthError.tokenExchange(401, "").isCredentialRejected)
        check("invalid_grant is terminal whatever the status",
              OAuthError.tokenExchange(500, #"{"error":"invalid_grant"}"#).isCredentialRejected)
        check("a 5xx is still worth retrying",
              !OAuthError.tokenExchange(503, "upstream").isCredentialRejected)
        check("a timeout is still worth retrying", !OAuthError.timedOut.isCredentialRejected)

        // Concurrency. N callers, one network refresh — the poll tick, the
        // popover opening and a manual refresh routinely overlap.
        let single = TokenFake(bundle: TokenFake.bundle(refresh: "rotated"), delay: 0.05)
        let vault = TokenVault(
            refresher: single.refresh, storedToken: { _ in "stored" },
            persist: single.persist, lock: { _ in nil }
        )
        let subject = Account(email: "c@example.com", refreshToken: "stored")
        let tokens = Blocking.run {
            await withTaskGroup(of: String?.self) { group in
                for _ in 0..<12 {
                    group.addTask { try? await vault.accessToken(for: subject) }
                }
                var out: [String?] = []
                for await token in group { out.append(token) }
                return out
            }
        }
        check("12 concurrent callers refresh exactly once", single.refreshes == 1,
              "\(single.refreshes) refreshes")
        check("…and every one of them gets the token", tokens.allSatisfy { $0 == "access" },
              "\(tokens.compactMap { $0 }.count)/12 served")
        check("…and the rotation is persisted exactly once", single.persists == 1,
              "\(single.persists) writes")
        check("the rotated token is the one persisted",
              single.persisted.last?.token == "rotated" && single.persisted.last?.expected == "stored")
        // A cached access token costs nothing at all.
        _ = Blocking.run { try? await vault.accessToken(for: subject) }
        check("a live access token is served from memory", single.refreshes == 1)

        // Ordering. The persist has to happen before any caller can act on the
        // bundle — a process killed in that gap loses a token the server has
        // already rotated.
        let ordered = TokenFake(bundle: TokenFake.bundle(refresh: "rotated"), delay: 0)
        let orderedVault = TokenVault(
            refresher: ordered.refresh, storedToken: { _ in "stored" },
            persist: ordered.persist, lock: { _ in nil }
        )
        _ = Blocking.run { try? await orderedVault.accessToken(for: subject) }
        ordered.log.append("returned")
        check("rotation is persisted before the bundle is returned",
              ordered.log == ["refreshed", "persisted", "returned"], "got \(ordered.log)")

        // And a persist that fails is a failure, not a silently dead account.
        let unwritable = TokenFake(bundle: TokenFake.bundle(refresh: "rotated"), delay: 0)
        unwritable.persistError = FileError.syscall("write", EIO)
        let unwritableVault = TokenVault(
            refresher: unwritable.refresh, storedToken: { _ in "stored" },
            persist: unwritable.persist, lock: { _ in nil }
        )
        let failed: Bool = Blocking.run {
            do { _ = try await unwritableVault.accessToken(for: subject); return false }
            catch { return true }
        }
        check("a failed persist surfaces as an error", failed)
        let served = Blocking.run { try? await unwritableVault.accessToken(for: subject) }
        check("…and the unpersisted token is never cached and served",
              served == nil, "got \(served ?? "nil")")

        // A rejected credential stops dead: no second request, and the raw
        // response body never leaves the vault.
        let dead = TokenFake(
            bundle: TokenFake.bundle(refresh: nil), delay: 0,
            error: OAuthError.tokenExchange(400, #"{"error":"invalid_grant","error_descript"#)
        )
        let deadVault = TokenVault(
            refresher: dead.refresh, storedToken: { _ in "consumed" },
            persist: dead.persist, lock: { _ in nil }
        )
        let rejection: Rejection = Blocking.run {
            do {
                _ = try await deadVault.accessToken(for: subject)
                return Rejection(isExpired: false, description: "no error at all")
            } catch {
                return Rejection(
                    isExpired: (error as? OAuthError) == .credentialExpired,
                    description: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
        check("a rejected refresh surfaces as the sanitized error", rejection.isExpired,
              "got \(rejection.description)")
        check("no response body escapes the vault",
              !rejection.description.contains("invalid_grant")
              && !rejection.description.contains("{"),
              "got \(rejection.description)")
        _ = Blocking.run { try? await deadVault.accessToken(for: subject) }
        check("a rejected account never hits the network again", dead.refreshes == 1,
              "\(dead.refreshes) refreshes")
        check("…until a sign-in revives it", Blocking.run {
            await deadVault.reset(subject.id)
            return await deadVault.isRejected(subject.id) == false
        })

        // A second copy of the app is a second consumer of the same rotated
        // token, and in-process single-flight cannot see it. The account is
        // skipped rather than raced — and skipping is transient, never terminal.
        let contended = TokenFake(bundle: TokenFake.bundle(refresh: "rotated"), delay: 0)
        let contendedVault = TokenVault(
            refresher: contended.refresh, storedToken: { _ in "stored" },
            persist: contended.persist, lock: { _ in throw OAuthError.refreshBusy }
        )
        let busy: Rejection = Blocking.run {
            do {
                _ = try await contendedVault.accessToken(for: subject)
                return Rejection(isExpired: false, description: "no error at all")
            } catch {
                return Rejection(
                    isExpired: (error as? OAuthError) == .refreshBusy,
                    description: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
        check("a refresh held by another process is refused", busy.isExpired,
              "got \(busy.description)")
        check("…without spending the token", contended.refreshes == 0 && contended.persists == 0)
        check("…and reads as transient, never as a dead credential",
              !OAuthError.refreshBusy.isCredentialRejected
              && !AppState.outcome(for: OAuthError.refreshBusy).isNeedsSignIn)

        // And the real lock: exclusive across descriptors, released on demand.
        let lockDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FablemeterLock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockID = UUID()
        let firstLock = try? RefreshLock.acquire(for: lockID, in: lockDirectory)
        check("the refresh lock is taken", firstLock != nil)
        var contendedLock = false
        do { _ = try RefreshLock.acquire(for: lockID, in: lockDirectory) }
        catch { contendedLock = (error as? OAuthError) == .refreshBusy }
        check("a held refresh lock refuses a second holder", contendedLock)
        firstLock?.release()
        let reacquired = try? RefreshLock.acquire(for: lockID, in: lockDirectory)
        check("releasing it lets the next holder in", reacquired != nil)
        reacquired?.release()
        // A directory that cannot hold a lock file must never stop a refresh.
        let unlockable = try? RefreshLock.acquire(
            for: lockID, in: URL(fileURLWithPath: "/dev/null/nowhere")
        )
        check("an impossible lock fails open rather than shut", unlockable == nil)
        try? FileManager.default.removeItem(at: lockDirectory)

        // The state that failure maps to, and what the loop then does with it.
        check("a rejected credential maps to needsSignIn",
              AppState.outcome(for: OAuthError.credentialExpired).isNeedsSignIn)
        check("a raw 400 maps to needsSignIn too",
              AppState.outcome(for: OAuthError.tokenExchange(400, "{\"e")).isNeedsSignIn)
        check("a rate limit is still an ordinary failure",
              !AppState.outcome(for: UsageError.rateLimited(retryAfter: nil)).isNeedsSignIn)
        check("needsSignIn carries no message to leak",
              AppState.outcome(for: OAuthError.tokenExchange(400, "{\"e")).message == nil)
        check("a transient failure still carries one",
              AppState.outcome(for: UsageError.http(503)).message == "HTTP 503")

        // Nothing that can carry a response body may reach the screen — not the
        // verdict slot, not the sign-in banner. `Token exchange failed (400):
        // {"e...` is exactly what this forbids.
        let bodies = [
            OAuthError.tokenExchange(400, #"{"error":"invalid_grant"}"#),
            OAuthError.tokenExchange(503, #"{"error":"overloaded_error"}"#),
            OAuthError.denied(#"{"error":"access_denied"}"#),
            OAuthError.credentialExpired,
            OAuthError.malformed,
            OAuthError.timedOut
        ]
        check("no OAuth failure puts a body on screen",
              bodies.allSatisfy { !$0.displayText.contains("{") && !$0.displayText.contains("\"") },
              "got \(bodies.map(\.displayText))")
        check("a transient token exchange still shows its status, not its body",
              AppState.outcome(for: OAuthError.tokenExchange(503, #"{"error":"x"}"#)).message
              == "sign-in failed (503)")
        check("the sign-in banner is sanitized too",
              AppState.signInMessage(for: OAuthError.tokenExchange(400, #"{"e"#))
              == "sign-in failed (400)")
        check("…while the log still gets the whole body",
              OAuthError.tokenExchange(400, #"{"error":"invalid_grant"}"#)
                  .errorDescription?.contains("invalid_grant") == true)

        let never = Date(timeIntervalSince1970: 0)
        var blocked = RetrySchedule()
        blocked.recordFailure(.rateLimited, now: epoch) { _ in 0 }
        check("the poll loop skips an account that needs signing in",
              !AppState.isDue(
                  needsSignIn: true, retry: nil, lastAttempt: nil,
                  reason: .scheduled, now: epoch
              ))
        check("…and a manual refresh cannot force one either",
              !AppState.isDue(
                  needsSignIn: true, retry: nil, lastAttempt: never,
                  reason: .manual, now: epoch
              ))
        check("a healthy account is still due",
              AppState.isDue(
                  needsSignIn: false, retry: nil, lastAttempt: nil,
                  reason: .scheduled, now: epoch
              ))
        check("backoff still gates everything else",
              !AppState.isDue(
                  needsSignIn: false, retry: blocked, lastAttempt: nil,
                  reason: .manual, now: epoch
              ))
        // A dead credential is terminal, so it must be un-due under *every*
        // combination the loop can present — otherwise three signed-out accounts
        // are three accounts the loop retries on every single tick, for ever.
        var dueWhenDead: [String] = []
        for reason in [RefreshReason.scheduled, .opportunistic, .manual] {
            for retry in [nil, blocked, RetrySchedule()] as [RetrySchedule?] {
                for last in [nil, never, epoch, epoch.addingTimeInterval(-86_400)] as [Date?] {
                    if AppState.isDue(
                        needsSignIn: true, retry: retry, lastAttempt: last,
                        reason: reason, now: epoch
                    ) { dueWhenDead.append("\(reason)/\(String(describing: last))") }
                }
            }
        }
        check("a signed-out account is never due, under any reason or history",
              dueWhenDead.isEmpty, dueWhenDead.first ?? "")
        // …and a backed-off account stays un-due right up to its deadline, so a
        // failure can never leave the loop re-firing every tick.
        check("a backed-off account is un-due until its block expires",
              !AppState.isDue(needsSignIn: false, retry: blocked, lastAttempt: nil,
                              reason: .scheduled, now: epoch.addingTimeInterval(299))
              && AppState.isDue(needsSignIn: false, retry: blocked, lastAttempt: nil,
                                reason: .scheduled, now: epoch.addingTimeInterval(301)))

        // Offline is the one failure whose own ladder outranks the staleness
        // gate. Without this the 15s rung is meaningless: the scheduled reason
        // would still hold the account for a full five minutes, and the app
        // would take minutes to notice the network had come back.
        var offlineRetry = RetrySchedule()
        offlineRetry.recordFailure(.offline, now: epoch) { _ in 0 }
        check("an offline account is blocked for its own 15 seconds",
              !AppState.isDue(needsSignIn: false, retry: offlineRetry, lastAttempt: epoch,
                              reason: .scheduled, now: epoch.addingTimeInterval(14)))
        check("…then due again immediately, without waiting out the interval",
              AppState.isDue(needsSignIn: false, retry: offlineRetry, lastAttempt: epoch,
                             reason: .scheduled, now: epoch.addingTimeInterval(16)))
        // The 429 ladder gets no such exemption: with its block expired it still
        // has to clear the staleness gate as well.
        check("a rate-limited account is still held by the staleness gate too",
              !AppState.isDue(
                  needsSignIn: false, retry: blocked,
                  lastAttempt: epoch.addingTimeInterval(200),
                  reason: .scheduled, now: epoch.addingTimeInterval(301)
              ))
        // And an offline account that has been signed out is still terminal.
        check("offline cannot resurrect a dead credential",
              !AppState.isDue(needsSignIn: true, retry: offlineRetry, lastAttempt: nil,
                              reason: .scheduled, now: epoch.addingTimeInterval(600)))

        // The footer's reload control: seen for long enough to mean something,
        // and never held up past what the refresh itself took.
        check("the spinner is visible for at least a third of a second",
              PollPolicy.minimumSpin >= 0.3 && PollPolicy.minimumSpin <= 1)
        check("an instant refresh still shows a full spin",
              PollPolicy.spinPadding(elapsed: 0) == PollPolicy.minimumSpin)
        check("a slow refresh is not padded at all",
              PollPolicy.spinPadding(elapsed: 5) == 0
              && PollPolicy.spinPadding(elapsed: PollPolicy.minimumSpin) == 0)
        check("padding never runs backwards", PollPolicy.spinPadding(elapsed: -1) >= 0)

        // On screen it is a state, not an error string.
        let rejectedState = AccountState(snapshot: nil, error: nil, needsSignIn: true)
        check("needsSignIn holds no error text", rejectedState.error == nil)
        check("…and still reads as unreachable, so the gauge stays hollow",
              rejectedState.isUnreachable && !rejectedState.isStale)
        check("a hollow, empty gauge is the never-loaded treatment",
              BarCell(character: "I", headroom: nil, isUnreachable: true)
              == BarCell(character: "I", headroom: rejectedState.snapshot?.headroom,
                         isUnreachable: rejectedState.isUnreachable))

        // MARK: Fable-first is a policy about the minimum, not about the data
        //
        // ON is today's behaviour — the fixture's 26 — and the bare `headroom`
        // property is that case by definition. OFF takes Fable out of the
        // minimum entirely, so the modes only diverge when Fable is the binding
        // constraint, and yellow — which announces "the gauge dropped Fable" —
        // can never show when there was no Fable in the gauge to drop.
        check("fable-first on is the fixture's 26", snap.headroom(fableFirst: true) == 26)
        check("…and is what the bare property means",
              snap.headroom == snap.headroom(fableFirst: true))
        check("fable-first off reads 26 here too — session binds, not Fable",
              snap.headroom(fableFirst: false) == 26)

        var pinched = UsageSnapshot()
        pinched.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: 40, resetsAt: nil)
        pinched.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: 20, resetsAt: nil)
        pinched.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: 94, resetsAt: nil)]
        check("Fable binding: on measures it", pinched.headroom(fableFirst: true) == 6)
        check("…off ignores it", pinched.headroom(fableFirst: false) == 60)

        var spent = pinched
        spent.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: 100, resetsAt: nil)]
        let fableSpentState = AccountState(snapshot: spent, error: nil, needsSignIn: false)
        let onCell = BarCell.cell(character: "F", state: fableSpentState, fableFirst: true)
        let offCell = BarCell.cell(character: "F", state: fableSpentState, fableFirst: false)
        check("Fable spent: on goes yellow",
              BarRenderer.showsFableYellow(
                  headroom: onCell.headroom, fableExhausted: onCell.isFableExhausted))
        check("…off never does",
              !BarRenderer.showsFableYellow(
                  headroom: offCell.headroom, fableExhausted: offCell.isFableExhausted))
        check("…and both agree on the number once Fable is out of the minimum",
              onCell.headroom == offCell.headroom && offCell.headroom == 60)

        var noFable = pinched
        noFable.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: nil, resetsAt: nil)]
        check("a null Fable reading is absent from the minimum, not zero",
              noFable.headroom(fableFirst: true) == 60)
        check("…while off leaves it out by policy — same number, different fact",
              noFable.headroom(fableFirst: false) == 60 && !noFable.isFableExhausted)

        // MARK: Start on login enrolls itself exactly once
        //
        // The default is ON, but only the first launch of the installed app
        // may act on it. Anything else silently re-registering — a demo run, a
        // bare `swift run` binary, or launch number two after the user said no
        // — would override a choice the user already made.
        check("first bundled launch enrolls",
              LoginItem.shouldAutoEnroll(attempted: false, demo: false, bundled: true))
        check("a second launch does not re-enroll",
              !LoginItem.shouldAutoEnroll(attempted: true, demo: false, bundled: true))
        check("demo never enrolls",
              !LoginItem.shouldAutoEnroll(attempted: false, demo: true, bundled: true))
        check("a bare swift-run binary never enrolls",
              !LoginItem.shouldAutoEnroll(attempted: false, demo: false, bundled: false))

        // MARK: The push payload keeps null and zero apart on the wire
        //
        // The web companion draws from this JSON alone, so the encoder is where
        // the null-versus-zero distinction either survives or silently dies at
        // the far end of a POST. Encoded with explicit NSNull, decoded back
        // here, and read the way the server will read it. The stamp date is
        // fixed so nothing in these checks consults a clock.
        let pushStamp = ISODate.parse("2026-08-12T01:40:00Z")!

        // Fable is the binding constraint (94% spent), so the two policies
        // disagree: Fable-first reads min(60, 80, 6) = 6, Fable-off min(60, 80)
        // = 60 — the same discriminating shape the gauge checks use.
        let pushFirst = Account(email: "p@example.com", label: "P", refreshToken: "unused")
        var pushSnap = UsageSnapshot()
        pushSnap.fiveHour = UsageBucket(
            id: "session", label: "5-hour", percent: 40, resetsAt: pushStamp)
        pushSnap.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: 20, resetsAt: nil)
        pushSnap.scoped = [UsageBucket(id: "scoped:Fable", label: "Fable", percent: 94, resetsAt: nil)]

        // A reported zero, a sent-but-null reading, an absent bucket, and a
        // failing newest fetch — every fact the wire has to carry, on one row.
        let pushSecond = Account(email: "z@example.com", label: "Z", refreshToken: "unused")
        var mixedSnap = UsageSnapshot()
        mixedSnap.fiveHour = UsageBucket(id: "session", label: "5-hour", percent: 0, resetsAt: nil)
        mixedSnap.weekly = UsageBucket(id: "weekly", label: "Weekly", percent: nil, resetsAt: nil)

        // Never loaded at all.
        let pushThird = Account(email: "n@example.com", label: "N", refreshToken: "unused")

        let pushAccounts = [pushFirst, pushSecond, pushThird]
        let pushStates: [UUID: AccountState] = [
            pushFirst.id: AccountState(snapshot: pushSnap),
            pushSecond.id: AccountState(snapshot: mixedSnap, error: "Timed out"),
            pushThird.id: AccountState(),
        ]

        func pushJSON(fableFirst: Bool) -> [[String: Any]] {
            let data = try? PushPayload.data(
                accounts: pushAccounts, states: pushStates,
                fableFirst: fableFirst, now: pushStamp
            )
            let root = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            return root?["accounts"] as? [[String: Any]] ?? []
        }
        func pushBucket(_ row: [String: Any]?, _ name: String) -> [String: Any]? {
            (row?["buckets"] as? [String: Any])?[name] as? [String: Any]
        }
        let pushOn = pushJSON(fableFirst: true)
        let pushOff = pushJSON(fableFirst: false)

        check("push carries every account", pushOn.count == 3, "got \(pushOn.count)")
        check("a null reading pushes as null, not zero",
              pushBucket(pushOn.dropFirst().first, "weekly")?["percent"] is NSNull)
        check("a reported zero pushes as 0",
              JSONScalar.number(pushBucket(pushOn.dropFirst().first, "fiveHour")?["percent"]) == 0)
        check("an absent bucket pushes as a null reading",
              pushBucket(pushOn.dropFirst().first, "fable")?["percent"] is NSNull)
        check("push headroom follows Fable-first on",
              JSONScalar.number(pushOn.first?["headroom"]) == 6,
              "got \(reading(JSONScalar.number(pushOn.first?["headroom"])))")
        check("…and Fable-first off",
              JSONScalar.number(pushOff.first?["headroom"]) == 60,
              "got \(reading(JSONScalar.number(pushOff.first?["headroom"])))")
        check("push verdict follows the same policy",
              pushOn.first?["verdict"] as? String == "Almost out"
              && pushOff.first?["verdict"] as? String == "Available")
        check("a never-loaded account pushes null headroom and No data",
              pushOn.last?["headroom"] is NSNull
              && pushOn.last?["verdict"] as? String == "No data")
        check("isStale travels",
              pushOn.dropFirst().first?["isStale"] as? Bool == true
              && pushOn.first?["isStale"] as? Bool == false)
        check("push reset stamps survive a round trip",
              ISODate.parse(pushBucket(pushOn.first, "fiveHour")?["resetsAt"] as? String) == pushStamp)
        check("push carries exactly the contract's keys — no email, no token",
              pushOn.first.map { Set($0.keys) }
              == Set(["id", "label", "nickname", "headroom", "verdict", "isStale", "buckets"]))

        // MARK: The web connect handoff
        //
        // Izu's own design: the site mints a one-time code and hands it to a
        // listener that exists only for the redirect. What these pin: the URL
        // shape the site expects, the state discipline (a public repo means a
        // public port scheme, so state is the whole defense), where the key
        // may live, and that a rejected key stops pushing without touching
        // the gauge.
        let cURL = URLComponents(
            url: Connect.connectURL(port: 49152, state: "s-abc"), resolvingAgainstBaseURL: false
        )
        check("connect URL points at the site's /connect",
              cURL?.host == "fablemeter.oniconic.app" && cURL?.path == "/connect")
        check("…carrying the port and the state",
              cURL?.queryItems?.contains(URLQueryItem(name: "port", value: "49152")) == true
              && cURL?.queryItems?.contains(URLQueryItem(name: "state", value: "s-abc")) == true)
        let hex = (try? Connect.randomHex(bytes: 16)) ?? ""
        check("connect state is 32 hex characters",
              hex.count == 32 && hex.allSatisfy { "0123456789abcdef".contains($0) }, hex)
        // The state is minted fail-closed: a dead entropy source refuses the
        // whole attempt, and nothing quieter than the real source will do.
        check("a dead entropy source refuses to mint a state",
              (try? Connect.randomHex(bytes: 16, using: { _ in nil })) == nil)
        check("…as the vetted entropy error",
              { do { _ = try Connect.randomHex(bytes: 16, using: { _ in nil }); return false }
                catch { return error as? ConnectError == .entropyFailed } }())
        check("a short read counts as a dead source too",
              (try? Connect.randomHex(bytes: 16, using: { _ in [0xab] })) == nil)
        check("an injected source still mints proper hex",
              (try? Connect.randomHex(bytes: 2, using: { count in
                  [UInt8](repeating: 0xab, count: count)
              })) == "abab")

        check("a matching callback yields its code",
              (try? Connect.code(from: ["code": "c1", "state": "s"], expecting: "s")) == "c1")
        check("a state mismatch is refused",
              (try? Connect.code(from: ["code": "c1", "state": "evil"], expecting: "s")) == nil)
        check("a callback with no code is refused",
              (try? Connect.code(from: ["state": "s"], expecting: "s")) == nil)

        func keyStore(keychain: String?, file: String?) -> PushKeyStore {
            PushKeyStore(
                readKeychain: { keychain }, writeKeychain: { _ in true }, readFile: { file }
            )
        }
        check("the Keychain key outranks the file",
              keyStore(keychain: "kc", file: "file").currentKey() == "kc")
        check("the file stands in when the Keychain is empty",
              keyStore(keychain: nil, file: "file").currentKey() == "file")
        check("neither store means no key",
              keyStore(keychain: nil, file: nil).currentKey() == nil)

        check("a rejected key stops pushing", Pusher.isSuppressed(key: "k", rejected: "k"))
        check("a fresh key resumes", !Pusher.isSuppressed(key: "k2", rejected: "k"))
        check("no key is not a rejection", !Pusher.isSuppressed(key: nil, rejected: nil))

        let named = PushPayload.body(accounts: [], states: [:], fableFirst: true, machine: "Izu's Mac")
        check("the payload names the machine", named["machine"] as? String == "Izu's Mac")
        let unnamed = PushPayload.body(accounts: [], states: [:], fableFirst: true)
        check("…and omits it when unnamed, rather than nulling it",
              unnamed["machine"] == nil)

        // MARK: The curated demo trio
        //
        // `--demo 3` is for product shots; the full set is for eyeballing
        // every state and reads as a wall of failures in a screenshot.
        let everyState = AppState.demoData()
        check("bare --demo keeps the full every-state set",
              everyState.accounts.count == 9
              && everyState.states.values.contains { $0.error != nil }
              && everyState.states.values.contains { $0.needsSignIn })
        let trio = AppState.demoData(count: 3)
        check("--demo 3 seeds the showcase trio",
              trio.accounts.map(\.nickname) == ["Personal", "Work", "Team"])
        check("…every one healthy and painted",
              trio.states.values.allSatisfy { $0.error == nil && !$0.needsSignIn && $0.snapshot != nil })
        let trioHeadrooms = trio.accounts.compactMap {
            trio.states[$0.id]?.snapshot?.headroom(fableFirst: true)
        }
        check("…spread comfortable / mid / tight",
              trioHeadrooms == [85, 45, 12], "\(trioHeadrooms)")
        check("…with the tight one in the orange tier, not red",
              trioHeadrooms.last.map { $0 <= 25 && $0 > 10 } == true)
        check("asking for more than the showcase holds gets all of it",
              AppState.demoData(count: 7).accounts.count == 3)

        ConnectAudit.run(check: check)

        // MARK: Sign-in loopback
        //
        // Reconnecting a second account without quitting first. The listener is
        // the only piece of the sign-in that can be exercised without a browser
        // — and it was the piece that broke: an abandoned flow parked forever on
        // a continuation that ignored cancellation, so `signIn` never returned,
        // never released port 8317, and never cleared "Signing in…". Every later
        // reconnect was then a silent no-op until the app was relaunched.
        CallbackLoop.audit(cycles: 3, delayMilliseconds: 0, check: check)

        print(failures == 0 ? "\nselftest: all checks passed" : "\nselftest: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Self test support

struct Rejection: Sendable {
    let isExpired: Bool
    let description: String
}

extension FetchOutcome {
    var isNeedsSignIn: Bool {
        if case .needsSignIn = self { return true }
        return false
    }

    /// What would reach the popover. `nil` for anything that has no business
    /// putting a string on screen.
    var message: String? {
        if case .failure(let message, _, _) = self { return message }
        return nil
    }

    /// Which retry ladder this failure was routed onto.
    var failureKind: Backoff.Failure? {
        if case .failure(_, let kind, _) = self { return kind }
        return nil
    }

    /// The reading this outcome carries, if any. Only `.success` can, and the
    /// tests assert exactly that: no failure classification anywhere in
    /// `outcome(for:)` may arrive holding a snapshot it made up.
    var snapshot: UsageSnapshot? {
        if case .success(let snapshot) = self { return snapshot }
        return nil
    }
}

/// A `TokenVault` collaborator with no network behind it: it counts refreshes,
/// records the order things happened in, and can be told to fail its write.
final class TokenFake: @unchecked Sendable {
    private let lock = NSLock()
    private let bundle: TokenBundle
    private let delay: TimeInterval
    private let error: Error?
    var persistError: Error?

    private(set) var refreshes = 0
    private(set) var persists = 0
    private(set) var persisted: [(token: String, expected: String)] = []
    var log: [String] = []

    init(bundle: TokenBundle, delay: TimeInterval, error: Error? = nil) {
        self.bundle = bundle
        self.delay = delay
        self.error = error
    }

    static func bundle(refresh: String?) -> TokenBundle {
        TokenBundle(
            accessToken: "access", refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(3600), email: nil
        )
    }

    var refresh: TokenVault.Refresher {
        { [self] _ in
            lock.withLock { refreshes += 1 }
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if let error { throw error }
            lock.withLock { log.append("refreshed") }
            return bundle
        }
    }

    var persist: TokenVault.Persister {
        { [self] _, token, expected in
            if let persistError { throw persistError }
            lock.withLock {
                persists += 1
                persisted.append((token, expected))
                log.append("persisted")
            }
        }
    }
}

/// Runs an async body from the synchronous self test. `--selftest` is a
/// command-line pass with no run loop, so blocking the caller is fine.
enum Blocking {
    static func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
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
            // Stale at the other end of the gauge: an idle account whose newest
            // fetch failed. It has to sit next to `X` below, because the two are
            // the pair most easily confused — both hollow, and only one of them
            // has actually lost anything. This one is showing a real reading of
            // "nothing used"; `X` is showing no reading at all.
            BarCell(character: "Z", headroom: 100, isUnreachable: true),   // stale, idle
            BarCell(character: "T", headroom: 85, isUnreachable: false),   // healthy
            BarCell(character: "X", headroom: nil, isUnreachable: true),   // never loaded
            // The residual case: the fetch worked and measured nothing. Rare
            // now that a reported zero counts as a reading, but it has to be
            // visible here, because it is the one that used to draw as a
            // painted empty track — a blocked account with a brighter letter.
            BarCell(character: "N", headroom: nil, isUnreachable: false),   // no reading
            BarCell(character: "F", headroom: 100, isUnreachable: false),  // full
            // Fable spent: the letter goes yellow and the gauge measures what is
            // left of the session and the week…
            BarCell(character: "Y", headroom: 70, isUnreachable: false, isFableExhausted: true),
            // …and gives the yellow back once there is nothing left to point at,
            // because then it is just another blocked account.
            BarCell(character: "B", headroom: 0, isUnreachable: false, isFableExhausted: true)
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

// MARK: - Popover render

/// Draws the popover itself, in both appearances, without a menu bar or a
/// click. Same reason as `RenderStates`: the states worth judging are not all
/// reachable on the machine doing the judging.
@MainActor
enum RenderPopover {
    static func run(into directory: String) -> Int32 {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        for (name, backdrop, spinning) in [
            (NSAppearance.Name.aqua, NSColor(white: 0.96, alpha: 1), false),
            (NSAppearance.Name.darkAqua, NSColor(white: 0.13, alpha: 1), false),
            // The footer mid-refresh, which no still of the resting popover
            // shows and which is exactly where a height change would be seen.
            (NSAppearance.Name.aqua, NSColor(white: 0.96, alpha: 1), true)
        ] {
            guard let appearance = NSAppearance(named: name) else { continue }
            let state = AppState(demo: true)
            if spinning { state.beginDemoSpin() }
            let host = NSHostingView(rootView: PopoverView(state: state))
            host.appearance = appearance
            // The popover's own material is opaque; without a backdrop the
            // capture is white-on-transparent and the dark case reads as blank.
            host.wantsLayer = true
            host.layer?.backgroundColor = backdrop.cgColor
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)

            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless],
                backing: .buffered, defer: false
            )
            window.appearance = appearance
            window.backgroundColor = backdrop
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let suffix = spinning ? "-refreshing" : ""
            let file = url.appendingPathComponent("popover-\(name.rawValue)\(suffix).png")
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("wrote \(file.path)  \(Int(size.width))x\(Int(size.height))")
            }
            window.orderOut(nil)
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
        let name = label.padding(toLength: 10, withPad: " ", startingAt: 0)
        guard let bucket, let percent = bucket.percent else {
            print("  \(name) —  \(bucket == nil ? "absent" : "null percent")")
            return
        }
        let reset = bucket.resetsAt.map { "resets \(Format.countdown(to: $0)) (\($0))" } ?? "no reset"
        print("  \(name) \(Int(percent.rounded()))%  \(reset)")
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

// MARK: - Callback loop

/// Exercises the loopback half of the sign-in flow, repeatedly, in one process
/// — everything `OAuth.signIn` does with the listener, minus the browser and
/// the credentials. The point is what a *single* run can never show: whether a
/// finished flow, or an abandoned one, leaves anything behind that the next
/// reconnect trips over.
/// The connect handoff, exercised the way `CallbackLoop` exercises sign-in's
/// listener: really binding, really hitting it over local HTTP, really
/// abandoning it. What is different here — and what these checks exist for —
/// is the ephemeral port, and the listener refusing a wrong-state callback
/// at the socket without consuming the attempt.
enum ConnectAudit {
    /// A `Connect.run` with the site played by `redirect` and the network
    /// stubbed out. Returns "stored" on success, the error's display text
    /// otherwise.
    private static func drive(
        timeout: TimeInterval,
        code: String = "c-42",
        redirect: @escaping @Sendable (_ port: String, _ state: String) -> Void
    ) async -> String {
        final class Box: @unchecked Sendable { var key: String? }
        let box = Box()
        let store = PushKeyStore(
            readKeychain: { nil },
            writeKeychain: { box.key = $0; return true },
            readFile: { nil }
        )
        do {
            try await Connect.run(
                timeout: timeout,
                exchange: { received in
                    guard received == code else { throw ConnectError.malformed }
                    return "key-42"
                },
                store: store,
                open: { url in
                    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let port = comps?.queryItems?.first { $0.name == "port" }?.value ?? "0"
                    let state = comps?.queryItems?.first { $0.name == "state" }?.value ?? ""
                    redirect(port, state)
                }
            )
            return box.key == "key-42" ? "stored" : "wrong key"
        } catch {
            return (error as? ConnectError)?.displayText ?? "\(error)"
        }
    }

    private static func hit(_ port: String, code: String, state: String) async -> Int {
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=\(code)&state=\(state)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (_, response) = (try? await URLSession.shared.data(for: request)) ?? (Data(), URLResponse())
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func run(check: (String, Bool, String) -> Void) {
        // 1. The advertised port is real: an ephemeral bind reports what the
        // kernel assigned, and the whole handoff completes against it.
        let happy = CallbackLoop.bounded(seconds: 12) {
            await drive(timeout: 5) { port, state in
                Task.detached { _ = await hit(port, code: "c-42", state: state) }
            }
        }
        check("a full handoff on an ephemeral port stores the exchanged key",
              happy == "stored", happy ?? "HUNG")

        // 2. A guessed callback — right port, wrong state — is answered as a
        // stranger and does not consume the attempt: the real redirect still
        // lands afterwards. The repo is public, so the port scheme is public;
        // this is the check that a guesser gets nothing.
        final class Status: @unchecked Sendable { var wrongState = 0 }
        let status = Status()
        let guessed = CallbackLoop.bounded(seconds: 12) {
            await drive(timeout: 6) { port, state in
                Task.detached {
                    status.wrongState = await hit(port, code: "evil", state: "guessed")
                    _ = await hit(port, code: "c-42", state: state)
                }
            }
        }
        check("a wrong-state callback cannot consume the handoff",
              guessed == "stored", guessed ?? "HUNG")
        check("…and is answered as a stranger",
              status.wrongState == 404, "got \(status.wrongState)")

        // 3. Abandoned — the browser never comes back. It times out rather
        // than wedging, exactly like the sign-in it is built on.
        let abandoned = CallbackLoop.bounded(seconds: 12) {
            await drive(timeout: 0.5) { _, _ in }
        }
        check("an abandoned connect times out instead of hanging",
              abandoned == "connect timed out", abandoned ?? "HUNG")

        // 4. …and the next handoff after an abandoned one still works: the
        // ephemeral listener was genuinely torn down.
        let after = CallbackLoop.bounded(seconds: 12) {
            await drive(timeout: 5) { port, state in
                Task.detached { _ = await hit(port, code: "c-42", state: state) }
            }
        }
        check("a connect after an abandoned one still works",
              after == "stored", after ?? "HUNG")

        // 5. The listener's bind is pinned to loopback. Behavioral proof for
        // "127.0.0.1 only" would need a second interface; pinning the
        // required host refuses the drift that matters — someone widening
        // the bind to "any".
        let host = CallbackLoop.bounded(seconds: 12) {
            do {
                return try await LoopbackCallback.withServer(ports: [0]) { server in
                    "\(server.requiredHost)"
                }
            } catch { return "\(error)" }
        }
        check("the handoff listener is required onto loopback",
              host == "127.0.0.1", host ?? "HUNG")
    }
}

enum CallbackLoop {
    /// One listen → redirect → resolve → stop cycle, structured exactly the way
    /// `OAuth.signIn` structures it. `deliver: false` abandons the flow, which
    /// is what a closed tab or a browser the user walks away from looks like.
    @discardableResult
    static func cycle(
        nonce: String, timeout: TimeInterval = 3, deliver: Bool = true
    ) async throws -> UInt16 {
        try await LoopbackCallback.withServer(ports: Constants.callbackPorts) { server in
            let url = URL(string: "http://127.0.0.1:\(server.port)/callback?code=\(nonce)&state=\(nonce)")!
            let hit = Task.detached {
                guard deliver else { return }
                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                _ = try? await URLSession.shared.data(for: request)
            }
            defer { hit.cancel() }

            let params = try await OAuth.firstOf(timeout: timeout) {
                try await server.awaitCallback()
            }
            guard params["code"] == nonce else { throw OAuthError.stateMismatch }
            return server.port
        }
    }

    /// Runs `body` on its own task and refuses to wait forever for it — the
    /// harness cannot use a task group here, because a task group is the very
    /// thing being tested for hanging. `ConnectAudit` borrows it for the same
    /// reason.
    static func bounded(
        seconds: Double, _ body: @escaping @Sendable () async -> String
    ) -> String? {
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { box.value = await body(); semaphore.signal() }
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.value
    }

    private static func outcome(_ error: Error?) -> String {
        guard let error else { return "resolved" }
        return (error as? OAuthError)?.displayText ?? "\(error)"
    }

    static func run(cycles: Int, delayMilliseconds: Int) -> Int32 {
        var failures = 0
        audit(cycles: cycles, delayMilliseconds: delayMilliseconds) { name, ok, detail in
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  \(detail)")")
            if !ok { failures += 1 }
        }
        print(failures == 0 ? "\ncallback-loop: all checks passed" : "\ncallback-loop: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    /// Synchronous, so `--selftest` — a command-line pass with no run loop —
    /// can run exactly the same checks as `--callback-loop`.
    static func audit(
        cycles: Int, delayMilliseconds: Int, check: (String, Bool, String) -> Void
    ) {
        // 1. Back-to-back reconnects.
        for i in 1...cycles {
            if i > 1, delayMilliseconds > 0 { usleep(UInt32(delayMilliseconds) * 1000) }
            let started = Date()
            let result = bounded(seconds: 12) {
                do { return "port \(try await cycle(nonce: "n\(i)"))" }
                catch { return outcome(error) }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            check("cycle \(i) delivers its callback",
                  result?.hasPrefix("port") == true, "\(result ?? "HUNG") \(ms)ms")
        }

        // 2. An abandoned flow — no callback ever arrives. It has to give up at
        // the timeout and hand back an error. Hanging here is not a slow
        // sign-in: it is a sign-in that never ends, holding the port and the
        // "signing in" flag until the app is relaunched.
        let started = Date()
        let abandoned = bounded(seconds: 12) {
            do { _ = try await cycle(nonce: "abandoned", deliver: false); return "resolved" }
            catch { return outcome(error) }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        check("an abandoned sign-in times out instead of hanging",
              abandoned == "sign-in timed out", "\(abandoned ?? "HUNG") \(ms)ms")

        // 3. …and having abandoned one, the next reconnect still works. This is
        // the user-visible bug: the second reconnect in a session.
        let after = bounded(seconds: 12) {
            do { return "port \(try await cycle(nonce: "after"))" }
            catch { return outcome(error) }
        }
        check("a reconnect after an abandoned one still works",
              after == "port \(Constants.callbackPorts[0])", after ?? "HUNG")

        // 4. A listener left running cannot swallow the next flow's callback.
        let stranded = bounded(seconds: 12) {
            guard (try? await LoopbackCallback.start(ports: Constants.callbackPorts)) != nil
            else { return "no port" }
            do { return "port \(try await cycle(nonce: "beside"))" }
            catch { return outcome(error) }
        }
        check("a still-running listener cannot swallow the next callback",
              stranded == "port \(Constants.callbackPorts[0])", stranded ?? "HUNG")

        // 5. A browser opens more sockets than it sends requests on (preconnect,
        // Happy Eyeballs). An accepted connection nobody closed keeps the port
        // alive after the listener is cancelled, and the next flow then binds a
        // port the authorize request was never told about.
        let idle = bounded(seconds: 12) {
            guard let first = try? await LoopbackCallback.start(ports: Constants.callbackPorts)
            else { return "no port" }
            let socketHandle = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = first.port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            await first.stop()
            defer { close(socketHandle) }
            guard let next = try? await LoopbackCallback.start(ports: Constants.callbackPorts)
            else { return "no port" }
            let port = next.port
            await next.stop()
            return "port \(port)"
        }
        check("an idle browser socket does not cost the next flow its port",
              idle == "port \(Constants.callbackPorts[0])", idle ?? "HUNG")
    }
}
