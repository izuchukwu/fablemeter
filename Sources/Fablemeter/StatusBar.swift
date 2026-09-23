import AppKit
@testable import FablemeterCore
import Combine
import SwiftUI

/// One account's presence in the menu bar: a capsule gauge over a single character.
///
/// The two fields are independent, and that is what lets the gauge say two
/// things at once. `isUnreachable` is about the *connection* — it hollows the
/// track. `headroom` is about the *reading* — it fills the track. So a rate
/// limited account still shows the last number it managed to fetch, inside a
/// hollow track that says the number is no longer live.
struct BarCell: Equatable {
    let character: Character
    /// Remaining headroom, 0...100. `nil` when nothing has ever resolved.
    let headroom: Double?
    /// The newest attempt failed — rate limited, offline, errored.
    let isUnreachable: Bool
    /// Fable's week is spent, so `headroom` is measuring the non-Fable windows
    /// only. Independent of the other two: it says what is being *measured*,
    /// where `headroom` says how much of it is left and `isUnreachable` says how
    /// old that is.
    let isFableExhausted: Bool

    /// The track is drawn hollow rather than painted. Two ways to earn it, and
    /// they are the same statement: there is no live reading behind this gauge.
    /// Either nothing arrived (`isUnreachable`) or what arrived measured nothing
    /// (`headroom == nil`). Keying only off the connection left the second case
    /// drawing a painted, empty track — one alpha step from a blocked account,
    /// which is the pair the eye most needs kept apart. With both on the same
    /// axis the four states read cleanly:
    ///
    ///     painted + level  live data
    ///     painted + empty  blocked, and the server said so
    ///     outline + level  stale — last known reading, no longer refreshing
    ///     outline + empty  no reading
    var isOutlined: Bool { isUnreachable || headroom == nil }

    init(
        character: Character,
        headroom: Double?,
        isUnreachable: Bool,
        isFableExhausted: Bool = false
    ) {
        self.character = character
        self.headroom = headroom
        self.isUnreachable = isUnreachable
        self.isFableExhausted = isFableExhausted
    }

    /// How an account's state becomes a cell, under a policy. Pure, and the one
    /// place the Fable-first switch is applied, so the selftest drives the same
    /// composition the status item draws. With Fable-first off the exhaustion
    /// flag is dropped *here*, not in the snapshot: Fable being spent is still a
    /// fact about the account, it just is not something this gauge is measuring,
    /// so the letter must not go yellow over it.
    static func cell(
        character: Character, state: AccountState?, fableFirst: Bool
    ) -> BarCell {
        BarCell(
            character: character,
            headroom: state?.snapshot?.headroom(fableFirst: fableFirst),
            isUnreachable: state?.isUnreachable == true,
            isFableExhausted: fableFirst && state?.snapshot?.isFableExhausted == true
        )
    }
}

/// Draws the status item image by hand. `MenuBarExtra`'s SwiftUI label cannot
/// produce this, and the menu bar wants a template image so the system can dim
/// and invert it — so colour only appears as a warning, like the battery icon.
enum BarRenderer {
    static let barWidth: CGFloat = 3.5
    static let barHeight: CGFloat = 11
    /// Just wide enough for the glyph; the cells read as one cluster, not as
    /// three separate menu bar items.
    ///
    /// What actually sets the density is the *pitch* — `cellWidth + cellSpacing`
    /// — because the glyph is centred in its cell, so the gap between two
    /// neighbouring letters is `pitch - glyphWidth` however the pitch is split.
    /// At 8pt medium the widest single character a label can hold is `W`, which
    /// inks about 7pt, and that is the floor everything here is set against: the
    /// 9pt pitch below leaves ~2pt of daylight between two adjacent `W`s —
    /// measured on screen, four pixels at 2x — and more between ordinary
    /// letters, while the gauges themselves sit 5.5pt apart. The cluster still
    /// keeps the ~20pt clearance from its neighbour that any two native menu bar
    /// items have, so it reads as one item rather than three.
    static let cellWidth: CGFloat = 7.5
    static let cellSpacing: CGFloat = 1.5
    static let outerPadding: CGFloat = 2.5
    static let gap: CGFloat = 1.5
    static let fontSize: CGFloat = 8
    static let imageHeight: CGFloat = 22
    static let minimumFill: CGFloat = 1.5
    /// The painted track, when the reading is live.
    static let trackAlpha: CGFloat = 0.20
    /// The hollow track, when it is not. Stronger than the painted track so the
    /// outline reads as a deliberate treatment rather than a faded one.
    static let outlineAlpha: CGFloat = 0.45
    static let outlineWidth: CGFloat = 1
    /// An account with nothing left is unusable, so its letter recedes. This is
    /// the "you cannot use this one" signal — the letters never take colour.
    static let blockedGlyphAlpha: CGFloat = 0.38

    /// `nil` means healthy — draw monochrome and let the system tint it.
    static func warningColor(for headroom: Double?) -> NSColor? {
        guard let headroom else { return nil }
        if headroom <= 10 { return .systemRed }
        if headroom <= 25 { return .systemOrange }
        return nil
    }

    /// The warning colour **as actually painted** — `nil` when the level is
    /// monochrome, and equally when there is no level to paint at all. A blocked
    /// account is red by tier and empty by fill, and an empty gauge inks nothing:
    /// asking for the colour of a bar that isn't drawn is what used to take a
    /// whole cluster out of template mode for no visible colour.
    static func levelColor(for cell: BarCell) -> NSColor? {
        guard fillHeight(headroom: cell.headroom ?? 0) > 0 else { return nil }
        return warningColor(for: cell.headroom)
    }

    /// Whether the letter is yellow: Fable is spent **and there is somewhere
    /// else to go**. Yellow is a redirection, not an alarm — it says the gauge
    /// beside it has stopped counting Fable and is measuring what remains. Once
    /// nothing remains there is no redirection left to offer, so a fully blocked
    /// account drops back to the ordinary blocked treatment: dimmed label ink,
    /// exactly as it read before yellow existed.
    static func showsFableYellow(headroom: Double?, fableExhausted: Bool) -> Bool {
        guard fableExhausted else { return false }
        guard let headroom else { return true }
        return headroom > 0
    }

    /// Whether anything in the cluster is drawn in a real colour — a painted
    /// warning level, or a yellow letter. That is what takes the whole image out
    /// of template mode, because a template image is flattened to the system's
    /// own tint and would swallow both. Nothing else earns it: an image that
    /// leaves template mode stops inverting with the menu bar, so the test is
    /// ink that is actually laid down, not a tier that happens to be reached.
    static func forcesColor(_ cells: [BarCell]) -> Bool {
        cells.contains { cell in
            levelColor(for: cell) != nil
                || showsFableYellow(
                    headroom: cell.headroom, fableExhausted: cell.isFableExhausted
                )
        }
    }

    /// The ink everything that isn't coloured is drawn in — the track, and every
    /// ordinary character. `.black` is the template-image stand-in for "whatever
    /// the system tints this to"; once any cell forces real colour, the menu
    /// bar's own `labelColor` takes over, which is white on a dark menu bar and
    /// black on a light one.
    static func neutralColor(colored: Bool) -> NSColor {
        colored ? .labelColor : .black
    }

    /// The yellow a letter takes once its gauge has dropped Fable.
    ///
    /// `systemYellow` is a *fill* colour, and it only works against a dark menu
    /// bar. Measured against the bar itself, an 8pt glyph drawn in it reaches
    /// 11.7:1 on a dark bar but **1.3:1 on a light one**, which is not a signal,
    /// it is a smudge. So the ink resolves against the appearance exactly the
    /// way every other letter does, black on light and white on dark:
    /// `systemYellow` on a dark bar, and a darker yellow of the same hue on a
    /// light one, which measures 4.1:1 instead. Both are far from the gauge's
    /// orange either way. Yellow is always drawn at full strength — the one
    /// state that would have dimmed it is the one state that no longer uses it.
    static let fableYellow = NSColor(name: "fableYellow") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.62, green: 0.41, blue: 0.02, alpha: 1)
    }

    /// Characters never carry the *warning* colour — the letters stay uniform
    /// and only the gauge level goes orange/red. The one thing a letter does say
    /// in colour is which limit its gauge is measuring, and it only has that to
    /// say while there is a limit left worth measuring:
    ///
    ///   Fable spent, room elsewhere  → yellow, full strength
    ///   Fable spent, nothing left    → label ink, dimmed  (blocked)
    ///   Fable fine, nothing left     → label ink, dimmed  (blocked)
    ///   otherwise                    → label ink, full strength
    ///
    /// So yellow and the blocked dim never meet. They used to compose into a
    /// dimmed yellow, which said "go use another model" about an account that
    /// has no other model to go to — the dim is the whole story there.
    static func glyphColor(
        colored: Bool, fableExhausted: Bool = false, headroom: Double? = nil
    ) -> NSColor {
        showsFableYellow(headroom: headroom, fableExhausted: fableExhausted)
            ? fableYellow
            : neutralColor(colored: colored)
    }

    /// …but a letter does dim when its account is out, which is the one thing
    /// colour used to say and now doesn't. An unreachable account is not dimmed:
    /// its numbers are stale, not spent, and the hollow track already says so.
    static func glyphAlpha(headroom: Double?) -> CGFloat {
        guard let headroom, headroom <= 0 else { return 1 }
        return blockedGlyphAlpha
    }

    /// Height of the drawn level. Blocked is genuinely empty — no nub, nothing
    /// drawn — while a small-but-real headroom keeps a visible floor.
    static func fillHeight(headroom: Double) -> CGFloat {
        guard headroom > 0 else { return 0 }
        return min(barHeight, max(minimumFill, barHeight * CGFloat(headroom) / 100))
    }

    /// - Parameter appearance: pins `labelColor` to a specific appearance. Only
    ///   `--render`, which draws both menu bars into files, has any business
    ///   passing this. The status item leaves it `nil` on purpose: the drawing
    ///   handler runs lazily, inside whichever appearance AppKit has already made
    ///   current for the menu bar it is drawing into, which is more correct than
    ///   anything this could pin — and pinning it is what required watching
    ///   `effectiveAppearance`, which is what span the redraw loop.
    static func image(for cells: [BarCell], appearance: NSAppearance? = nil) -> NSImage {
        guard !cells.isEmpty else { return emptyImage() }

        let colored = forcesColor(cells)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let textHeight = ceil(font.ascender - font.descender)
        let contentHeight = barHeight + gap + textHeight
        let width = outerPadding * 2
            + CGFloat(cells.count) * cellWidth
            + CGFloat(cells.count - 1) * cellSpacing

        let image = NSImage(
            size: NSSize(width: width, height: imageHeight), flipped: false
        ) { _ in
            let draw = {
                let baseY = ((imageHeight - contentHeight) / 2).rounded()
                let barY = baseY + textHeight + gap
                let radius = barWidth / 2
                let neutral = neutralColor(colored: colored)

                for (index, cell) in cells.enumerated() {
                    // Like the battery icon: the track and the character stay
                    // monochrome, only the level goes orange/red.
                    let level: NSColor = levelColor(for: cell) ?? neutral

                    let cellX = outerPadding + CGFloat(index) * (cellWidth + cellSpacing)
                    let barRect = NSRect(
                        x: cellX + (cellWidth - barWidth) / 2, y: barY,
                        width: barWidth, height: barHeight
                    )
                    let capsule = NSBezierPath(
                        roundedRect: barRect, xRadius: radius, yRadius: radius
                    )

                    // The track says whether there is a live reading behind the
                    // gauge: painted when there is, hollow when there is not —
                    // whether that is because the fetch failed or because the
                    // fetch succeeded and measured nothing. So a hollow gauge
                    // means "no reading", and a painted one with nothing inside
                    // means "the reading says zero" — two different problems,
                    // two different pictures. See `BarCell.isOutlined`.
                    if cell.isOutlined {
                        let outline = NSBezierPath(
                            roundedRect: barRect.insetBy(
                                dx: outlineWidth / 2, dy: outlineWidth / 2
                            ),
                            xRadius: radius, yRadius: radius
                        )
                        outline.lineWidth = outlineWidth
                        neutral.withAlphaComponent(outlineAlpha).setStroke()
                        outline.stroke()
                    } else {
                        neutral.withAlphaComponent(trackAlpha).setFill()
                        capsule.fill()
                    }

                    // A failed fetch keeps drawing the last level it knew —
                    // losing the reading was the actual complaint.
                    let height = fillHeight(headroom: cell.headroom ?? 0)
                    if height > 0 {
                        // Square-cut level, clipped by the capsule so only the
                        // bottom cap rounds — a fuel gauge, not a floating dot.
                        NSGraphicsContext.saveGraphicsState()
                        capsule.addClip()
                        level.setFill()
                        NSBezierPath(rect: NSRect(
                            x: barRect.minX, y: barRect.minY,
                            width: barWidth, height: height
                        )).fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }

                    // Colour says which limit the gauge is measuring; the alpha
                    // says whether the account can be used at all — and the
                    // second answer can retire the first. A blocked account has
                    // no limit left to point at, so it takes the plain dimmed
                    // letter whether or not its Fable week is gone.
                    let glyphInk = glyphColor(
                        colored: colored,
                        fableExhausted: cell.isFableExhausted,
                        headroom: cell.headroom
                    )
                    let glyph = String(cell.character) as NSString
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: glyphInk.withAlphaComponent(
                            glyphAlpha(headroom: cell.headroom)
                        )
                    ]
                    let size = glyph.size(withAttributes: attributes)
                    glyph.draw(
                        at: NSPoint(x: cellX + (cellWidth - size.width) / 2, y: baseY),
                        withAttributes: attributes
                    )
                }
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        image.isTemplate = !colored
        // Never cached, so the handler above re-runs for every draw and resolves
        // `labelColor` against the appearance current at that moment. That is
        // what makes watching the button's appearance unnecessary — and the
        // watcher was a feedback loop, so removing the need for it is the fix.
        image.cacheMode = .never
        return image
    }

    private static func emptyImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let symbol = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "Fablemeter"
        )?.withSymbolConfiguration(config) {
            symbol.isTemplate = true
            return symbol
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let text = "Fablemeter" as NSString
        let size = text.size(withAttributes: [.font: font])
        let image = NSImage(
            size: NSSize(width: ceil(size.width) + 6, height: imageHeight), flipped: false
        ) { rect in
            text.draw(
                at: NSPoint(x: 3, y: (rect.height - size.height) / 2),
                withAttributes: [.font: font, .foregroundColor: NSColor.black]
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?
    private var renderedCells: [BarCell]?
    /// Live only while the popover is open. See `installOutsideClickMonitor`.
    private var outsideClickMonitor: Any?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let host = NSHostingController(rootView: PopoverView(state: state))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.toolTip = "Fablemeter"
        }

        cancellable = state.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires *before* the mutation lands.
            Task { @MainActor in self?.redraw() }
        }
        // Switching to another application — ⌘-tab, clicking its window, the
        // browser the sign-in opens — takes the popover with it. `.transient`
        // already does this one; keeping it explicit costs nothing and makes
        // the rule the code states the same rule it relies on.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfShown() }
        }
        redraw(force: true)
    }

    /// Assigns a new image **only when the cells actually changed**, and that
    /// restraint is load-bearing rather than an optimisation.
    ///
    /// `setImage:` makes the status item re-snapshot itself for its replicants,
    /// and rendering a replicant sets the button's appearance — which used to
    /// come back here through a `\.effectiveAppearance` observation that forced
    /// another `setImage:`. Watch that cycle for a second and it never stops:
    ///
    ///     setImage: → _adjustLength → _updateReplicantsUnlessMenuIsTracking:
    ///              → _redrawReplicantSnapshot: → -[NSView setAppearance:]
    ///              → effectiveAppearance KVO → setImage: → …
    ///
    /// That was a whole CPU core, permanently, with the popover shut. There is
    /// nothing left watching the appearance now: the image resolves its colours
    /// lazily at draw time instead (see `BarRenderer.image`), so an unchanged
    /// cluster costs exactly one comparison per state change and nothing else.
    private func redraw(force: Bool = false) {
        let cells = state.barCells
        guard force || cells != renderedCells else { return }
        renderedCells = cells
        guard let button = statusItem.button else { return }
        button.image = BarRenderer.image(for: cells)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        state.refreshIfStale()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installOutsideClickMonitor()
    }

    /// Closes the popover on the first click that lands anywhere outside this
    /// process, which is the half of "clicking away" that `.transient` misses.
    ///
    /// `.transient` is documented as closing when the user interacts with
    /// anything outside the popover, but what it actually watches is focus:
    /// the app resigning active, or the popover's window resigning key. For a
    /// menu bar app there is a whole class of click that does neither —
    /// **clicking the desktop**, its widgets, or the wallpaper simply activates
    /// nothing. Traced with a build that logged every notification: a click on
    /// another app's window produced `resignKey` + `resignActive` and the
    /// popover closed; a click on the desktop produced *neither*, and the
    /// popover stayed up with the app still active. So the missing dismissal is
    /// not a focus change at all, and nothing that listens for one can fix it.
    ///
    /// A global monitor sees exactly the right events and no others, and that
    /// is what keeps the status item's own toggle intact: the button lives in
    /// this process, so clicking it is a *local* event this handler never sees.
    /// Nothing here can therefore race the button's action into the
    /// close-then-reopen flicker — the button remains the only thing that
    /// closes the popover when you click the thing that opened it. Clicks
    /// inside the popover, in its context menus, and in the label field are
    /// local for the same reason, and so is the sign-in flow's own UI; the
    /// browser it opens belongs to another process, which closes the popover on
    /// purpose while the sign-in — a task on the app state, not on the view —
    /// carries on regardless.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfShown() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    private func closeIfShown() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// However the popover went away — this, `.transient`, Escape — the monitor
    /// goes with it. It is the one thing here that costs anything while idle.
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
}
