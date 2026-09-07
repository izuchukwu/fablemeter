import AppKit

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--render") {
    let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "."
    exit(MainActor.assumeIsolated { RenderStates.run(into: directory) })
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
