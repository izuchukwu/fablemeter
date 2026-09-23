import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The HTTP seam, driven for real

/// Every request this app makes — token refresh, usage, profile, push, Slack,
/// connect, `/api/state`, `/api/promote` — goes through `HTTP.data(for:)`. Its
/// macOS branch once shipped as a call to itself, which hung every refresh and
/// every push on the Mac while every pure check stayed green, because nothing
/// under test ever sent a request through it. So this check does: a one-shot
/// HTTP server on 127.0.0.1, an ephemeral port, and a real round trip through
/// the seam on whichever platform the selftest is running on.
enum HTTPSeamCheck {
    static func run(_ check: CoreChecks.Check) {
        guard let server = OneShotServer(body: "fablemeter-seam-ok") else {
            check("http seam: a loopback server could be started", false, "socket/bind/listen failed")
            return
        }
        server.serveOnce()
        let url = URL(string: "http://127.0.0.1:\(server.port)/seam")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let done = DispatchSemaphore(value: 0)
        let result = Locked<(Int, String)?>(initialState: nil)
        Task.detached {
            if let (data, response) = try? await HTTP.data(for: request) {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                result.withLock { $0 = (code, String(decoding: data, as: UTF8.self)) }
            }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 10) == .success
        let got = result.withLock { $0 }
        check("http seam: a real request through HTTP.data(for:) returns, on this platform",
              finished && got?.0 == 200 && got?.1 == "fablemeter-seam-ok",
              finished ? "got \(got.map { "\($0.0) \($0.1)" } ?? "an error")" : "timed out")
        server.close()
    }
}

/// Accepts one connection, answers 200 with a fixed body, and stops. Bound to
/// loopback only, on a port the kernel picks.
final class OneShotServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let body: String

    init?(body: String) {
        self.body = body
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s >= 0 else { return nil }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(s, 1) == 0 else { _ = systemClose(s); return nil }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard named == 0 else { _ = systemClose(s); return nil }
        fd = s
        port = UInt16(bigEndian: actual.sin_port)
    }

    func serveOnce() {
        let fd = self.fd, body = self.body
        Thread.detachNewThread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &buffer, buffer.count)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { write(client, $0, strlen($0)) }
            _ = systemClose(client)
        }
    }

    func close() { _ = systemClose(fd) }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.close(fd)
    #else
    return Darwin.close(fd)
    #endif
}
