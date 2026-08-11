import AppKit
import SwiftUI

// MARK: - Formatting

enum Format {
    /// Compact countdown: `3d 04h`, `1h 08m`, `12m`, `now`.
    static func countdown(to date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return String(format: "%dd %02dh", days, hours) }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return "\(max(minutes, 1))m"
    }

    static func relative(_ date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

/// Plain-language reading of headroom — the verdict shown before any number.
enum Verdict {
    static func word(headroom: Double?) -> String {
        guard let headroom else { return "Unknown" }
        if headroom > 40 { return "Available" }
        if headroom > 10 { return "Limited" }
        if headroom > 0 { return "Almost out" }
        return "Blocked"
    }

    /// Monochrome until something is wrong — same thresholds as the menu bar.
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

/// Usage meter — filled means consumed, the inverse of the menu bar gauge.
struct UsageMeter: View {
    let percent: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }
}

struct MetricRow: View {
    let title: String
    let bucket: UsageBucket?
    let now: Date

    private var present: Bool { bucket?.hasData == true }
    private var percent: Double { bucket?.percent ?? 0 }
    private var tint: Color {
        present ? Verdict.color(usedPercent: percent) : .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            UsageMeter(
                percent: present ? percent : 0,
                tint: present ? (tint == .secondary ? Color.primary.opacity(0.55) : tint) : .clear
            )

            Text(present ? "\(Int(percent.rounded()))%" : "—")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(present ? tint : Color.secondary)
                .frame(width: 32, alignment: .trailing)

            Text(present ? Format.countdown(to: bucket?.resetsAt, from: now) : "—")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
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

    let account: Account
    let state: AccountState?
    let now: Date
    let setLabel: (String) -> Void
    let setNickname: (String) -> Void
    let remove: () -> Void

    @State private var editingLabel = false
    @State private var editingName = false
    @State private var labelDraft = ""
    @State private var nameDraft = ""
    @FocusState private var focus: Field?

    private var headroom: Double? { state?.snapshot?.headroom }

    private var verdict: (text: String, color: Color) {
        if let error = state?.error { return (error, .orange) }
        guard state?.snapshot != nil else { return ("—", .secondary) }
        return (Verdict.word(headroom: headroom), Verdict.color(headroom: headroom))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LabelToken(
                character: account.label,
                draft: $labelDraft,
                isEditing: $editingLabel,
                focus: $focus,
                commit: commitLabel
            )
            .onTapGesture(perform: beginLabelEdit)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if editingName {
                        TextField("", text: $nameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .focused($focus, equals: .name)
                            .onSubmit(commitName)
                    } else {
                        Text(account.nickname)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .onTapGesture(count: 2, perform: beginNameEdit)
                    }
                    Spacer(minLength: 6)
                    Text(verdict.text)
                        .font(.system(size: 11))
                        .foregroundStyle(verdict.color)
                        .lineLimit(1)
                }

                Text(account.email)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                VStack(alignment: .leading, spacing: 3) {
                    MetricRow(title: "5-hour", bucket: state?.snapshot?.fiveHour, now: now)
                    MetricRow(title: "Weekly", bucket: state?.snapshot?.weekly, now: now)
                    MetricRow(title: "Fable", bucket: state?.snapshot?.fable, now: now)
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Set Label…", action: beginLabelEdit)
            Button("Rename…", action: beginNameEdit)
            Divider()
            Button("Remove Account", action: remove)
        }
        .onChange(of: focus) { old, _ in
            if old == .label { commitLabel() }
            if old == .name { commitName() }
        }
    }

    private func beginLabelEdit() {
        labelDraft = account.label
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
        nameDraft = account.nickname
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

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        AccountRow(
                            account: account,
                            state: state.state(for: account),
                            now: context.date,
                            setLabel: { state.setLabel($0, for: account) },
                            setNickname: { state.setNickname($0, for: account) },
                            remove: { state.remove(account) }
                        )
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
        .onAppear { state.refreshIfStale() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !state.accounts.isEmpty {
                Text(state.isSigningIn ? "Signing in…" : "Updated \(Format.relative(state.lastUpdated))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("Add Account…") { state.addAccount() }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 11))
                .focusable(false)
                .disabled(!state.canAddAccount)

            Menu {
                Button("Refresh") { state.manualRefresh() }
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
        .controlSize(.small)
        .focusEffectDisabled()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
