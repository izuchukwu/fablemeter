import Foundation

enum AccountSelection {
    /// An explicit menu selection uses the existing locked, verified switch
    /// implementation. No refresh token is ever read by the app.
    static func select(label: String) -> String? {
        guard let helper = Bundle.main.url(forResource: "fablemeter-select", withExtension: nil) else {
            return "Account switch helper is missing. Reinstall Fablemeter."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Budget.python)
        process.arguments = [helper.path, label]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonempty ?? "Could not switch accounts."
        } catch {
            return "Could not start the account switcher."
        }
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
