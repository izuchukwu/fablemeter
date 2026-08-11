import AppKit

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--selftest") {
    exit(SelfTest.run())
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
