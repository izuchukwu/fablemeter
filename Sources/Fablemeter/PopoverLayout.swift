import AppKit
import QuartzCore
import SwiftUI

/// The display-link transaction sizes both the graph and its popover. AppKit
/// resizing is immediate; scrolling starts only at the available screen height.
@MainActor
final class PopoverScrollController<Content: View>: NSViewController {
    let scroll = NSScrollView()
    let document: PopoverDocument<AnyView>
    let viewport = HistoryViewport()
    weak var popover: NSPopover?
    private let maximumHeight: CGFloat

    init(rootView: Content, maximumHeight: CGFloat = .greatestFiniteMagnitude) {
        self.maximumHeight = maximumHeight
        document = PopoverDocument(rootView: AnyView(rootView.frame(maxHeight: .infinity, alignment: .top).environment(\.historyViewport, viewport)))
        super.init(nibName: nil, bundle: nil)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        document.frame.size.width = 300
        document.sizingOptions = [.intrinsicContentSize]
        document.resized = { [weak self] in self?.layoutDocument() }
        viewport.changed = { [weak self] in self?.layoutDocument() }
        view = scroll
        prepareForDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareForDisplay() {
        scroll.contentView.scroll(to: .zero)
        let height = min(max(160, document.fittingSize.height), heightLimit)
        preferredContentSize = NSSize(width: 300, height: height)
        scroll.frame.size = preferredContentSize
        layoutDocument()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // NSPopover establishes its final anchor and chrome after appearance.
        DispatchQueue.main.async { [weak self] in self?.layoutDocument() }
    }

    private var heightLimit: CGFloat {
        let screen = view.window?.screen ?? NSScreen.main
        // Include the popover chrome when measuring space below its fixed top.
        if let window = view.window, let screen {
            let chrome = window.frame.height - scroll.frame.height
            return floor(min(maximumHeight, window.frame.maxY - screen.visibleFrame.minY - chrome))
        }
        return min(maximumHeight, (screen?.visibleFrame.height ?? 800) - 40)
    }

    private var layingOut = false
    func layoutDocument() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let origin = scroll.contentView.bounds.origin
        let top = view.window?.frame.maxY
        // Give hosting enough room to flush the new SwiftUI phase without
        // minimum-size overflow translating the entire stack.
        document.frame.size.height = max(document.frame.height, document.fittingSize.height + 130)
        document.layoutSubtreeIfNeeded()
        let naturalHeight = document.fittingSize.height
        let height = min(max(160, naturalHeight), heightLimit)
        preferredContentSize = NSSize(width: 300, height: height)
        popover?.contentSize = preferredContentSize
        scroll.frame.size = NSSize(width: 300, height: height)
        if let top, let window = view.window, abs(window.frame.maxY - top) > 0.001 {
            var frame = window.frame
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: false, animate: false)
        }
        // Keep a scrolled click stationary even when collapse reduces the
        // document below the old scroll offset. The extra space is trailing.
        document.frame.size = NSSize(width: 300, height: max(naturalHeight, height + origin.y))
        document.layoutSubtreeIfNeeded()
        scroll.hasVerticalScroller = naturalHeight > height + 0.5
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
final class PopoverDocument<Content: View>: NSHostingView<Content> {
    var resized: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        resized?()
    }
}

@MainActor
final class HistoryViewport {
    private(set) var animations = 0
    var changed: (() -> Void)?
    func begin() { animations += 1; changed?() }
    func end() { animations -= 1; changed?() }
}

private struct HistoryViewportKey: EnvironmentKey {
    static let defaultValue: HistoryViewport? = nil
}

extension EnvironmentValues {
    var historyViewport: HistoryViewport? {
        get { self[HistoryViewportKey.self] }
        set { self[HistoryViewportKey.self] = newValue }
    }
}

/// One clock controls clipping, translation and opacity. No second implicit
/// SwiftUI or AppKit animation can commit the final layout ahead of the graph.
@MainActor
final class HistoryExpansion: NSObject, ObservableObject {
    static let duration = 0.260
    @Published private(set) var phase: Double = 0
    private(set) var expanded = false
    private var link: CADisplayLink?
    private var start = 0.0
    private var from = 0.0
    private var to = 0.0
    var afterFrame: (() -> Void)?
    weak var viewport: HistoryViewport?

    // NSPopover rounds its window size to whole points. Quantize the shared
    // geometry here so hosting and the window always use the same height.
    var height: CGFloat { (130 * (1 - pow(1 - phase, 3))).rounded() }
    var opacity: Double { max(0, min(1, (phase - 1.0 / 3) * 1.5)) }
    var isAnimating: Bool { link != nil }

    func toggle(reduceMotion: Bool = false) {
        expanded.toggle()
        stop()
        to = expanded ? 1 : 0
        if reduceMotion {
            phase = to
            viewport?.changed?()
            afterFrame?()
            return
        }
        from = phase
        start = CACurrentMediaTime()
        guard let screen = NSScreen.main else { phase = to; return }
        let displayLink = screen.displayLink(target: self, selector: #selector(tick(_:)))
        viewport?.begin()
        link = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func finish() {
        stop()
        phase = expanded ? 1 : 0
    }

    func stop() {
        if link != nil { viewport?.end() }
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - start
        let fraction = min(1, elapsed / (Self.duration * abs(to - from)))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { phase = from + (to - from) * fraction }
        viewport?.changed?()
        afterFrame?()
        if fraction >= 1 { stop() }
    }
}
