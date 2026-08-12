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
let delegate = MainActor.assumeIsolated { AppDelegate(demo: arguments.contains("--demo")) }
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
