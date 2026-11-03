import AppKit
import QuartzCore
import SwiftUI

/// A popover keeps the size chosen when it opens. Only the scroll document
/// grows. In particular, NSPopover never receives an animated ideal size.
@MainActor
final class PopoverScrollController<Content: View>: NSViewController {
    let scroll = NSScrollView()
    let document: PopoverDocument<AnyView>
    let viewport = HistoryViewport()
    private let maximumHeight: CGFloat

    init(rootView: Content, maximumHeight: CGFloat = 650) {
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
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 60
        let height = min(max(160, document.fittingSize.height), min(maximumHeight, available))
        preferredContentSize = NSSize(width: 300, height: height)
        scroll.frame.size = preferredContentSize
        layoutDocument()
    }

    private var layingOut = false
    func layoutDocument() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let origin = scroll.contentView.bounds.origin
        // Reserve each changing graph's maximum size BEFORE its first layout.
        // This prevents hosting's minimum-size overflow from centering a frame
        // that is briefly smaller than the new intrinsic size. Drop the reserve
        // at rest, retaining only enough trailing space to preserve scroll offset.
        let height = max(document.fittingSize.height + CGFloat(viewport.animations) * 130,
                         scroll.contentSize.height + origin.y)
        document.frame.size = NSSize(width: 300, height: height)
        document.layoutSubtreeIfNeeded()
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

    var height: CGFloat { 130 * (1 - pow(1 - phase, 3)) }
    var opacity: Double { max(0, min(1, (phase - 1.0 / 3) * 1.5)) }
    var isAnimating: Bool { link != nil }

    func toggle(reduceMotion: Bool = false) {
        expanded.toggle()
        stop()
        to = expanded ? 1 : 0
        if reduceMotion {
            phase = to
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
        afterFrame?()
        if fraction >= 1 { stop() }
    }
}
