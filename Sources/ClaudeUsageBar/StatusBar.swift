import AppKit
import Combine
import SwiftUI

/// One account's presence in the menu bar: a capsule gauge over a single character.
struct BarCell: Equatable {
    let character: Character
    /// Remaining headroom, 0...100. `nil` when nothing has resolved yet.
    let headroom: Double?
    let isError: Bool
}

/// Draws the status item image by hand. `MenuBarExtra`'s SwiftUI label cannot
/// produce this, and the menu bar wants a template image so the system can dim
/// and invert it — so colour only appears as a warning, like the battery icon.
enum BarRenderer {
    static let barWidth: CGFloat = 3.5
    static let barHeight: CGFloat = 11
    /// Just wide enough for the glyph; the cells read as one cluster, not as
    /// three separate menu bar items.
    static let cellWidth: CGFloat = 9
    static let cellSpacing: CGFloat = 3
    static let outerPadding: CGFloat = 2.5
    static let gap: CGFloat = 1.5
    static let fontSize: CGFloat = 8
    static let imageHeight: CGFloat = 22
    static let minimumFill: CGFloat = 1.5

    /// `nil` means healthy — draw monochrome and let the system tint it.
    static func warningColor(for headroom: Double?) -> NSColor? {
        guard let headroom else { return nil }
        if headroom <= 10 { return .systemRed }
        if headroom <= 25 { return .systemOrange }
        return nil
    }

    static func image(for cells: [BarCell]) -> NSImage {
        guard !cells.isEmpty else { return emptyImage() }

        let anyWarning = cells.contains { warningColor(for: $0.headroom) != nil }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let textHeight = ceil(font.ascender - font.descender)
        let contentHeight = barHeight + gap + textHeight
        let width = outerPadding * 2
            + CGFloat(cells.count) * cellWidth
            + CGFloat(cells.count - 1) * cellSpacing

        let image = NSImage(
            size: NSSize(width: width, height: imageHeight), flipped: false
        ) { _ in
            let baseY = ((imageHeight - contentHeight) / 2).rounded()
            let barY = baseY + textHeight + gap
            let radius = barWidth / 2

            for (index, cell) in cells.enumerated() {
                // A template image carries no colour, so `.black` is only a
                // stand-in for "whatever the system tints this to".
                let warning = warningColor(for: cell.headroom)
                let neutral: NSColor = anyWarning ? .labelColor : .black
                // Like the battery icon: the track stays monochrome, only the
                // level and its label go orange/red.
                let ink: NSColor = warning ?? neutral

                let cellX = outerPadding + CGFloat(index) * (cellWidth + cellSpacing)
                let barRect = NSRect(
                    x: cellX + (cellWidth - barWidth) / 2, y: barY,
                    width: barWidth, height: barHeight
                )
                let capsule = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)

                if cell.isError {
                    // Quiet, not alarming: an empty outline where the gauge goes.
                    let outline = NSBezierPath(
                        roundedRect: barRect.insetBy(dx: 0.5, dy: 0.5),
                        xRadius: radius, yRadius: radius
                    )
                    outline.lineWidth = 1
                    neutral.withAlphaComponent(0.85).setStroke()
                    outline.stroke()
                } else if let headroom = cell.headroom {
                    neutral.withAlphaComponent(0.20).setFill()
                    capsule.fill()

                    // Square-cut level, clipped by the capsule so only the
                    // bottom cap rounds — a fuel gauge, not a floating dot.
                    let fillHeight = max(minimumFill, barHeight * CGFloat(headroom) / 100)
                    NSGraphicsContext.saveGraphicsState()
                    capsule.addClip()
                    ink.setFill()
                    NSBezierPath(rect: NSRect(
                        x: barRect.minX, y: barRect.minY,
                        width: barWidth, height: fillHeight
                    )).fill()
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    // Unknown: the empty track alone.
                    neutral.withAlphaComponent(0.20).setFill()
                    capsule.fill()
                }

                let glyph = String(cell.character) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: ink
                ]
                let size = glyph.size(withAttributes: attributes)
                glyph.draw(
                    at: NSPoint(x: cellX + (cellWidth - size.width) / 2, y: baseY),
                    withAttributes: attributes
                )
            }
            return true
        }
        image.isTemplate = !anyWarning
        return image
    }

    private static func emptyImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let symbol = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "Claude usage"
        )?.withSymbolConfiguration(config) {
            symbol.isTemplate = true
            return symbol
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let text = "Claude" as NSString
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
    private var appearanceObservation: NSKeyValueObservation?
    private var renderedCells: [BarCell]?

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
            button.toolTip = "Claude usage"
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.redraw(force: true) }
            }
        }

        cancellable = state.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires *before* the mutation lands.
            Task { @MainActor in self?.redraw() }
        }
        redraw(force: true)
    }

    private func redraw(force: Bool = false) {
        let cells = state.barCells
        guard force || cells != renderedCells else { return }
        renderedCells = cells
        guard let button = statusItem.button else { return }
        // Resolve `labelColor` against the menu bar's own appearance.
        var image: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = BarRenderer.image(for: cells)
        }
        button.image = image
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
    }
}
