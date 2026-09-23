import AppKit
@testable import FablemeterCore
import SwiftUI


/// The colour half of the verdict; the words live in the core so the server
/// and the wire can say them too.
extension Verdict {
    static func color(headroom: Double?) -> Color {
        guard let headroom else { return .secondary }
        if headroom <= 10 { return .red }
        if headroom <= 25 { return .orange }
        return .secondary
    }

    static func color(usedPercent: Double) -> Color {
        color(headroom: 100 - usedPercent)
    }
}

// MARK: - Small components

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The footer's reload control, sitting immediately left of `⋯` and drawn at the
/// same weight so the two read as a pair. While a user-initiated refresh is in
/// flight it becomes a spinner in the *same* 16pt box — the footer cannot change
/// height between the two states — and stops taking clicks, so a second press
/// cannot stack a second pass behind the first.
struct ReloadButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    /// The `⋯` next to it is pinned to this too. Both states are laid out inside
    /// it rather than sizing it, which is what keeps the footer still.
    private static let side: CGFloat = 16

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .focusable(false)
        // Not `.disabled`: that dims the spinner to the point of looking broken.
        // Clicks are refused instead, and `manualRefresh` refuses a second pass
        // on its own anyway, so a double-click cannot stack one either way.
        .allowsHitTesting(!isRefreshing)
        .help("Refresh")
        .accessibilityLabel(isRefreshing ? "Refreshing" : "Refresh")
    }
}

/// Usage meter — filled means consumed, the inverse of the menu bar gauge, and
/// carrying the same two-state track: painted while the reading is live, hollow
/// once it isn't. An empty painted track is a real zero; an empty hollow track
/// is no data at all.
struct UsageMeter: View {
    let percent: Double
    let tint: Color
    /// The newest fetch failed. What is drawn is the last thing that arrived.
    let isUnreachable: Bool

    private var fraction: Double { max(0, min(1, percent / 100)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if isUnreachable {
                    Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                } else {
                    Capsule().fill(Color.primary.opacity(0.10))
                }
                if fraction > 0 {
                    Capsule()
                        // Held back while stale so the outline stays the thing
                        // the eye lands on.
                        .fill(tint.opacity(isUnreachable ? 0.45 : 1))
                        .frame(width: fraction * geo.size.width)
                }
            }
        }
        .frame(height: 5)
    }
}

/// What a metric row prints, and the two cases it must never merge.
///
/// A bucket the server reported as zero prints `0%` — it has genuinely used
/// nothing — with a dash for its reset, because a window that has not started
/// has nothing to reset. A bucket the server did not report prints a dash in
/// *both* columns: printing `0%` there would be the row asserting "you have used
/// nothing" while the verdict above it says "No data", and only one of those can
/// be true. The dash is the same mark the reset column already uses for the same
/// meaning.
enum MetricDisplay {
    static func percentText(_ bucket: UsageBucket?) -> String {
        guard let percent = bucket?.percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    static func resetText(
        _ bucket: UsageBucket?,
        from now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        Format.resetStamp(bucket?.resetsAt, from: now, locale: locale, timeZone: timeZone)
    }
}

struct MetricRow: View {
    let title: String
    let bucket: UsageBucket?
    let now: Date
    /// Passed down from the account: the whole row is as live as its fetch was.
    let isUnreachable: Bool

    /// Columns are sized off the widest string each can hold at its own weight:
    /// `100%` measures 32.2pt at 11pt medium, `Wed 12 PM` 61.2pt at 11pt
    /// regular. Both are pinned so neither can ever wrap again.
    private static let percentWidth: CGFloat = 36
    private static let resetWidth: CGFloat = 66

    private var percent: Double { bucket?.percent ?? 0 }
    private var tint: Color { Verdict.color(usedPercent: percent) }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            UsageMeter(
                percent: percent,
                tint: tint == .secondary ? Color.primary.opacity(0.55) : tint,
                isUnreachable: isUnreachable
            )

            Text(MetricDisplay.percentText(bucket))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.percentWidth, alignment: .trailing)

            Text(MetricDisplay.resetText(bucket, from: now))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.resetWidth, alignment: .trailing)
        }
    }
}

/// The single-character token. Click it to edit in place.
struct LabelToken: View {
    let character: String
    @Binding var draft: String
    @Binding var isEditing: Bool
    var focus: FocusState<AccountRow.Field?>.Binding
    let commit: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .focused(focus, equals: .label)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, new in
                        let clipped = String(new.uppercased().prefix(1))
                        if clipped != new { draft = clipped }
                    }
            } else {
                Text(character)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .frame(width: 20, height: 20)
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Account

struct AccountRow: View {
    enum Field: Hashable { case label, name }

    let row: DisplayRow
    let now: Date
    /// The verdict word is the gauge's reading put into words, so it follows
    /// the same policy the gauge does — the metric rows underneath do not: the
    /// Fable row keeps printing whatever the server said either way.
    let fableFirst: Bool
    /// Bumped when something outside the row is clicked — the cue to commit any
    /// in-place edit and give up focus.
    let dismissToken: Int
    /// The ends of the list disable rather than hide their move item, so the
    /// menu keeps the same shape wherever the account sits.
    let canMoveUp: Bool
    let canMoveDown: Bool
    let setLabel: (String) -> Void
    let setNickname: (String) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    /// A sign-in is already in the air. Only one can be, so the item says so by
    /// dimming rather than by accepting a click it would silently drop.
    let isSigningIn: Bool
    let signIn: () -> Void
    let signOut: () -> Void

    @State private var editingLabel = false
    @State private var editingName = false
    @State private var labelDraft = ""
    @State private var nameDraft = ""
    @FocusState private var focus: Field?

    private var state: AccountState? { row.state }
    /// A row the server measured: nothing on it acts on an account this Mac
    /// does not hold.
    private var isReadOnly: Bool { row.local == nil }
    private var headroom: Double? { state?.snapshot?.headroom(fableFirst: fableFirst) }
    private var isUnreachable: Bool { state?.isUnreachable == true }
    private var needsSignIn: Bool { state?.needsSignIn == true }
    /// A rejected credential with nothing behind it has no numbers to show —
    /// three rows of `0%  —` would only be noise around the one thing to do.
    private var showsMetrics: Bool { !(needsSignIn && state?.snapshot == nil) }

    /// The failure replaces the verdict word rather than the numbers: the row
    /// still shows the last reading that arrived, and this says why it may be
    /// old. That is the whole message — no sentence underneath it. A dead
    /// credential takes the same slot, as the action itself rather than a word.
    private var verdict: (text: String, color: Color) {
        if let error = state?.error { return (error, .orange) }
        guard state?.snapshot != nil else { return ("—", .secondary) }
        return (Verdict.word(headroom: headroom), Verdict.color(headroom: headroom))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LabelToken(
                character: row.label,
                draft: $labelDraft,
                isEditing: $editingLabel,
                focus: $focus,
                commit: commitLabel
            )
            .onTapGesture { if !isReadOnly { beginLabelEdit() } }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if editingName {
                        TextField("", text: $nameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .focused($focus, equals: .name)
                            .onSubmit(commitName)
                    } else {
                        Text(row.nickname)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .onTapGesture(count: 2) { if !isReadOnly { beginNameEdit() } }
                    }
                    Spacer(minLength: 6)
                    if needsSignIn && !isReadOnly {
                        Button("Reconnect", action: signIn)
                            .buttonStyle(PressableButtonStyle())
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .focusable(false)
                            .disabled(isSigningIn)
                    } else {
                        Text(verdict.text)
                            .font(.system(size: 11))
                            .foregroundStyle(verdict.color)
                            .lineLimit(1)
                    }
                }

                if let email = row.email {
                    Text(email)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if showsMetrics {
                    VStack(alignment: .leading, spacing: 3) {
                        MetricRow(
                            title: "5-hour", bucket: state?.snapshot?.fiveHour,
                            now: now, isUnreachable: isUnreachable
                        )
                        MetricRow(
                            title: "Weekly", bucket: state?.snapshot?.weekly,
                            now: now, isUnreachable: isUnreachable
                        )
                        MetricRow(
                            title: "Fable", bucket: state?.snapshot?.fable,
                            now: now, isUnreachable: isUnreachable
                        )
                    }
                    .padding(.top, 5)
                }
            }
        }
        .padding(.horizontal, 14)
        // Asymmetric on purpose: the block starts with cap-height text and ends
        // with a descender's worth of slack, so equal padding would leave every
        // divider hugging the metrics above it. A row with no metrics under it
        // already ends on a text baseline, so it takes the balanced pair.
        .padding(.top, 16)
        .padding(.bottom, showsMetrics ? 19 : 17)
        .contentShape(Rectangle())
        .contextMenu {
            // A server row belongs to the server; there is nothing here to do
            // to it.
            if !isReadOnly {
                Button("Reconnect Account…", action: signIn).disabled(isSigningIn)
                Divider()
                Button("Set Label…", action: beginLabelEdit)
                Button("Rename…", action: beginNameEdit)
                Divider()
                Button("Move Up", action: moveUp).disabled(!canMoveUp)
                Button("Move Down", action: moveDown).disabled(!canMoveDown)
                Divider()
                Button("Sign Out", action: signOut)
            }
        }
        .onChange(of: focus) { old, _ in
            if old == .label { commitLabel() }
            if old == .name { commitName() }
        }
        .onChange(of: dismissToken) { _, _ in
            commitLabel()
            commitName()
            focus = nil
        }
        // The popover can go away mid-edit (Escape, a click on another app);
        // the character typed still counts.
        .onDisappear {
            commitLabel()
            commitName()
        }
    }

    private func beginLabelEdit() {
        labelDraft = row.label
        editingLabel = true
        focus = .label
    }

    private func commitLabel() {
        guard editingLabel else { return }
        editingLabel = false
        setLabel(labelDraft)
        if focus == .label { focus = nil }
    }

    private func beginNameEdit() {
        nameDraft = row.nickname
        editingName = true
        focus = .name
    }

    private func commitName() {
        guard editingName else { return }
        editingName = false
        setNickname(nameDraft)
        if focus == .name { focus = nil }
    }
}

// MARK: - Reordering

/// The lifted row stays put and recedes; the thing under the cursor is the
/// drag preview. Scale settles from 1, never from 0.
struct LiftEffect: ViewModifier {
    let isLifted: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isLifted ? 0.98 : 1)
            .opacity(isLifted ? 0.35 : 1)
            .animation(.easeOut(duration: 0.12), value: isLifted)
    }
}

extension View {
    /// A lone account has nowhere to go, and an always-on `.onDrag` would still
    /// lift it out of the list.
    @ViewBuilder
    func onDrag(if enabled: Bool, _ provider: @escaping () -> NSItemProvider) -> some View {
        if enabled { onDrag(provider) } else { self }
    }
}

/// Catches the drop that lands in the popover but not on a row — the footer,
/// the padding, a divider — so the lifted row settles back instead of staying
/// dimmed.
struct LiftReleaseDelegate: DropDelegate {
    @Binding var draggingID: UUID?

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.easeOut(duration: 0.12)) { draggingID = nil }
        return true
    }
}

/// Reorders as the drag crosses a row rather than on drop, so the rows part
/// under the cursor and the menu bar cluster rearranges live. The account list
/// is the model, so there is nothing to commit afterwards — the drop only ends
/// the lift.
struct AccountDropDelegate: DropDelegate {
    let target: Account
    let state: AppState
    @Binding var draggingID: UUID?

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let draggingID, draggingID != target.id,
                  let source = state.accounts.first(where: { $0.id == draggingID })
            else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                state.move(source, onto: target)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let landed = draggingID != nil
            withAnimation(.easeOut(duration: 0.12)) { draggingID = nil }
            return landed
        }
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var state: AppState
    /// Incremented on every click in the popover; rows watch it to commit and
    /// drop focus.
    @State private var dismissToken = 0
    @State private var clickMonitor: Any?
    /// The account currently lifted out of the list, if any.
    @State private var draggingID: UUID?

    private var canReorder: Bool { !state.isFollowingServer && state.accounts.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fablemeter")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)
            Divider()

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.displayRows(now: context.date).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        rowView(row, now: context.date)
                    }
                }
            }

            if let error = state.signInError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if !state.accounts.isEmpty || state.signInError != nil { Divider() }
            footer
        }
        .frame(width: 300)
        // A drag released outside the popover reports nothing back, so the lift
        // is cleared on the way in and out rather than trusted to the drop.
        .onDrop(of: [.text], delegate: LiftReleaseDelegate(draggingID: $draggingID))
        .onAppear {
            draggingID = nil
            state.refreshIfStale()
            installClickMonitor()
        }
        .onDisappear {
            draggingID = nil
            removeClickMonitor()
        }
    }

    @ViewBuilder
    private func rowView(_ row: DisplayRow, now: Date) -> some View {
        let base = AccountRow(
            row: row,
            now: now,
            fableFirst: state.isFableFirst,
            dismissToken: dismissToken,
            canMoveUp: row.local.map { state.canMove($0, by: -1) } ?? false,
            canMoveDown: row.local.map { state.canMove($0, by: 1) } ?? false,
            setLabel: { value in if let account = row.local { state.setLabel(value, for: account) } },
            setNickname: { value in if let account = row.local { state.setNickname(value, for: account) } },
            moveUp: { if let account = row.local { withAnimation(.easeInOut(duration: 0.18)) { state.move(account, by: -1) } } },
            moveDown: { if let account = row.local { withAnimation(.easeInOut(duration: 0.18)) { state.move(account, by: 1) } } },
            isSigningIn: state.isSigningIn || state.isPromoting,
            signIn: { if let account = row.local { state.signInAgain(account) } },
            signOut: { if let account = row.local { state.remove(account) } }
        )
        if let account = row.local {
            base
                .modifier(LiftEffect(isLifted: draggingID == account.id))
                .onDrag(if: canReorder) {
                    draggingID = account.id
                    return NSItemProvider(object: account.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: AccountDropDelegate(target: account, state: state, draggingID: $draggingID)
                )
        } else {
            base
        }
    }

    /// A transparent hit target behind the rows never sees these clicks — the
    /// rows' own content shape and context menu swallow them first. Watching the
    /// window's mouse-*down* instead catches every click, and because a
    /// `TapGesture` only fires on mouse-*up* it can't race the label token:
    /// clicking the token commits whatever was open, then starts its edit.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            dismissToken &+= 1
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
    }

    private var footer: some View {
        ZStack {
            // With no accounts the popover is nothing but this footer, so the
            // one thing to do here has to be visible rather than hidden in ⋯.
            if state.accounts.isEmpty {
                Button("Add Account…") { state.addAccount() }
                    .buttonStyle(PressableButtonStyle())
                    .font(.system(size: 11))
                    .focusable(false)
                    .disabled(!state.canAddAccount)
            }

            HStack(spacing: 10) {
                if !state.accounts.isEmpty || state.isFollowingServer {
                    Text(state.footerText(now: Date()))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                // Two controls of the same weight sitting together, so the pair
                // reads as one cluster rather than as a button bolted onto a
                // menu.
                HStack(spacing: 8) {
                    ReloadButton(
                        isRefreshing: state.isManualRefreshing,
                        action: { state.manualRefresh() }
                    )

                    Menu {
                        Button("Add Account…") { state.addAccount() }
                            .disabled(!state.canAddAccount)
                        Button("Connect to Fablemeter Web…") { state.connectWeb() }
                            .disabled(state.isDemo || state.isConnectingWeb)
                        Menu("Server") { ServerMenuContent(state: state) }
                        Divider()
                        if LoginItem.isAvailable {
                            Toggle("Start on Login", isOn: Binding(
                                get: { LoginItem.isEnabled },
                                set: { LoginItem.set($0) }
                            ))
                        }
                        Toggle("Fable-first", isOn: $state.isFableFirst)
                        Menu("Warnings") {
                            Toggle("Warn at 75%", isOn: $state.warnAt75)
                            Toggle("Warn at 90%", isOn: $state.warnAt90)
                            Toggle("Warn at 95%", isOn: $state.warnAt95)
                            Divider()
                            Toggle("Warn on fast burn", isOn: $state.warnFastBurn)
                        }
                        Divider()
                        Button("Quit") { NSApplication.shared.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .focusable(false)
                    .frame(width: 16)
                }
            }
        }
        .controlSize(.small)
        .focusEffectDisabled()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}


/// The Server submenu, drawn from what the background poll already cached —
/// opening it never touches the network. One item can be clicked, and only
/// ever for this Mac; every other machine is listed for reference.
struct ServerMenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        ForEach(Array(state.serverMenuItems.enumerated()), id: \.offset) { _, item in
            switch item {
            case .caption(let text):
                Button(text) {}.disabled(true)
            case .machine(let title, let isServer):
                Toggle(title, isOn: .constant(isServer)).disabled(true)
            case .divider:
                Divider()
            case .makeThisMacServer(let enabled):
                Button("Make This Mac the Server") { state.promoteThisMac() }.disabled(!enabled)
            case .connect:
                Button("Connect to Fablemeter Web…") { state.connectWeb() }
                    .disabled(state.isDemo || state.isConnectingWeb)
            case .cancelPromotion:
                Button("Cancel Promotion") { state.cancelPromotion() }
            }
        }
    }
}
