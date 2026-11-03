import AppKit
@testable import FablemeterCore
import UserNotifications

let arguments = Set(CommandLine.arguments.dropFirst())

// Invoked by the local cascade only after a swap has been read back. Reuse
// this bundle's notification permission and the existing Slack destination.
if arguments.contains("--notify-swap") {
    struct SwapNotice: Decodable { let id: String; let title: String; let body: String }
    guard let notice = try? JSONDecoder().decode(
        SwapNotice.self, from: FileHandle.standardInput.readDataToEndOfFile()
    ) else { print("swap-notify: invalid notice"); exit(1) }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        async let slack = Slack.post(title: notice.title, body: notice.body)
        var native = false
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let center = UNUserNotificationCenter.current()
            do {
                if try await center.requestAuthorization(options: [.alert, .sound]) {
                    let content = UNMutableNotificationContent()
                    content.title = notice.title
                    content.body = notice.body
                    content.sound = .default
                    try await center.add(UNNotificationRequest(
                        identifier: notice.id, content: content, trigger: nil
                    ))
                    native = true
                }
            } catch { /* Report status without exposing message contents. */ }
        }
        let sent = await slack
        print("swap-notify: Slack \(sent ? "accepted" : "failed"), macOS \(native ? "accepted" : "denied or failed")")
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 25) == .timedOut {
        print("swap-notify: timed out")
        exit(1)
    }
    exit(0)
}

if arguments.contains("--check-expansion") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    exit(MainActor.assumeIsolated { ExpansionCheck.run() })
}

if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "."
    exit(MainActor.assumeIsolated { RenderStates.run(into: directory) })
}

if let index = CommandLine.arguments.firstIndex(of: "--render-live") {
    let file = CommandLine.arguments.dropFirst(index + 1).first ?? "fablemeter-live.png"
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    exit(MainActor.assumeIsolated { RenderLive.run(to: file) })
}

if let index = CommandLine.arguments.firstIndex(of: "--render-popover") {
    let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "."
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    exit(MainActor.assumeIsolated { RenderPopover.run(into: directory) })
}

if let index = CommandLine.arguments.firstIndex(of: "--callback-loop") {
    let rest = CommandLine.arguments.dropFirst(index + 1).compactMap(Int.init)
    exit(CallbackLoop.run(cycles: rest.first ?? 3, delayMilliseconds: rest.dropFirst().first ?? 0))
}

if arguments.contains("--slack-test") {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 1
    Task {
        status = await SlackTest.run()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status)
}

if arguments.contains("--oob-test") {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 1
    Task {
        status = await OOBTest.run()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status)
}

if arguments.contains("--probe") {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 1
    Task {
        status = await Probe.run()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status)
}

// Top-level code already runs on the main thread.
// `--demo` takes an optional count: `--demo 3` seeds the curated showcase trio
// (product shots) instead of the full every-state set.
let demoIndex = CommandLine.arguments.firstIndex(of: "--demo")
let demoCount = demoIndex.flatMap { CommandLine.arguments.dropFirst($0 + 1).first.flatMap(Int.init) }
let delegate = MainActor.assumeIsolated {
    AppDelegate(demo: demoIndex != nil, demoCount: demoCount)
}
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
