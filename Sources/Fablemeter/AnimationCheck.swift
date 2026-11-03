import AppKit
import SwiftUI
@testable import FablemeterCore

/// Enabled only by --check-expansion. Probes are actual views in the account
/// header and clipped graph, converted through the real popover window.
@MainActor
enum ExpansionCheck {
    static var enabled = false
    static var probes: [String: NSView] = [:]
    static var expansions: [String: HistoryExpansion] = [:]

    static func run() -> Int32 {
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        enabled = true
        let state = AppState(demo: true, demoCount: 3)
        let rows = state.displayRows(now: Date())
        let host = PopoverScrollController(rootView: PopoverView(state: state), maximumHeight: 350)
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .applicationDefined
        popover.animates = false
        // A dedicated anchor avoids hidden status items on crowded menu bars.
        let screen = NSScreen.main!.visibleFrame
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.midX, y: screen.maxY - 30, width: 30, height: 24),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        anchorWindow.contentView = button
        anchorWindow.orderFrontRegardless()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        settle()
        var failures = 0
        func check(_ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL") \(detail)")
            if !ok { failures += 1 }
        }
        func frame(_ key: String) -> NSRect {
            guard let view = probes[key], let window = view.window else { return .zero }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
        // First row, middle row and the last row with the viewport scrolled:
        // the latter catches automatic scroll clamping on collapse.
        for index in rows.indices {
            let id = "\(rows[index].id)"
            guard let expansion = expansions[id], let window = host.view.window else {
                check(false, "missing real row or popover: shown=\(popover.isShown) window=\(String(describing: host.view.window)) expansions=\(expansions.keys) size=\(host.document.frame)"); continue
            }
            if index == rows.count - 1 {
                host.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, host.document.frame.height - host.scroll.contentSize.height)))
                host.scroll.reflectScrolledClipView(host.scroll.contentView)
                settle()
                check(host.scroll.contentView.bounds.origin.y > 0, "last row exercised at a nonzero scroll offset")
            }
            let anchor = frame("account-\(id)")
            let initialPopover = window.frame
            for direction in ["expand", "collapse"] {
                var samples: [(Double, NSRect, NSRect, Double, Double, Double, Double, Double)] = []
                let start = CACurrentMediaTime()
                func sample() {
                    // Flush the ordinary display pass; never repair document
                    // sizing from the test before taking a measurement.
                    window.displayIfNeeded()
                    let below = index + 1 < rows.count ? frame("account-\(rows[index + 1].id)").minY : 0
                    samples.append((CACurrentMediaTime() - start, frame("account-\(id)"), window.frame,
                                    frame("graph-\(id)").height, below, expansion.phase, expansion.opacity, expansion.height))
                }
                sample()
                expansion.afterFrame = { sample() }
                expansion.toggle()
                let timeout = Date().addingTimeInterval(2)
                while expansion.isAnimating && Date() < timeout {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
                }
                settle()
                sample()
                expansion.afterFrame = nil
                check(!expansion.isAnimating && samples.count >= 8, "row \(index) \(direction) sampled every display callback")
                check(samples.allSatisfy { $0.1 == anchor }, "row \(index) \(direction) clicked screen frame invariant")
                check(samples.allSatisfy { $0.2 == initialPopover }, "row \(index) \(direction) popover frame constant (monotonic height)")
                let heights = samples.map { $0.3 }
                let pairs = zip(heights, heights.dropFirst())
                check(pairs.allSatisfy { direction == "expand" ? $1 >= $0 - 0.01 : $1 <= $0 + 0.01 }, "graph height monotonic")
                check(samples.allSatisfy { abs($0.3 - $0.7) <= 0.5 }, "rendered graph follows the clock within one backing pixel")
                check(samples.allSatisfy { $0.5 > 1.0 / 3 || $0.6 == 0 }, "contents remain transparent for first third")
                check(abs((heights.last ?? -1) - (direction == "expand" ? 130 : 0)) < 0.01, "graph reaches endpoint")
                if index + 1 < rows.count, let first = samples.first {
                    check(samples.allSatisfy { abs(($0.4 - first.4) + ($0.3 - first.3)) < 0.02 }, "following row translates by exactly graph height")
                }
                print("SAMPLES row=\(index) \(direction): ms,row[x y w h],popover[x y w h],graphH,belowY,phase,opacity")
                for s in samples {
                    func rect(_ r: NSRect) -> String {
                        String(format: "[%.3f %.3f %.3f %.3f]", r.minX, r.minY, r.width, r.height)
                    }
                    print(String(format: "%.2f", s.0 * 1000) + "," + rect(s.1) + "," + rect(s.2) + String(format: ",%.3f,%.3f,%.4f,%.4f", s.3, s.4, s.5, s.6))
                }
            }
        }
        if let first = rows.first, let expansion = expansions["\(first.id)"], let window = host.view.window {
            let anchor = frame("account-\(first.id)")
            let popoverFrame = window.frame
            var reversedFrames = 0
            var stable = true
            expansion.afterFrame = {
                window.displayIfNeeded()
                reversedFrames += 1
                stable = stable && frame("account-\(first.id)") == anchor && window.frame == popoverFrame
            }
            expansion.toggle()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let phase = expansion.phase
            expansion.toggle()
            check(expansion.phase == phase, "mid-flight reversal keeps the current height and opacity")
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            check(stable && reversedFrames >= 8 && expansion.phase == 0, "reversal keeps row and popover fixed through every frame")
            expansion.afterFrame = nil
            expansion.toggle(reduceMotion: true)
            window.displayIfNeeded()
            check(expansion.height == 130 && expansion.opacity == 1 && !expansion.isAnimating,
                  "Reduce Motion expands immediately")
            expansion.toggle(reduceMotion: true)
            window.displayIfNeeded()
            check(expansion.height == 0 && expansion.opacity == 0 && !expansion.isAnimating,
                  "Reduce Motion collapses immediately")
            check(host.viewport.animations == 0, "all display links and layout reserves released")
        }
        popover.close()
        anchorWindow.close()
        print("Expansion check: \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}

struct LayoutFrameProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if ExpansionCheck.enabled { ExpansionCheck.probes[id] = view }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
