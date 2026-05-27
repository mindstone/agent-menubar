import Foundation
import Darwin

/// Listens on a Unix domain socket at
/// ~/Library/Application Support/AgentMenuBar/sock for line-delimited JSON
/// emitted by hook bridge scripts.
///
/// Implementation: BSD socket(AF_UNIX, SOCK_STREAM) + DispatchSourceRead for
/// non-blocking accept(). NWListener has no first-class UDS server API on
/// macOS, so we keep this small and explicit.
final class HookSocketServer: @unchecked Sendable {
    enum SocketError: Error {
        case create(Int32)
        case bind(Int32)
        case listen(Int32)
        case pathTooLong
    }

    static var socketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sock")
    }

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "AgentMenuBar.HookSocket.accept")
    private let readQueue   = DispatchQueue(label: "AgentMenuBar.HookSocket.read", attributes: .concurrent)

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) throws {
        let url  = Self.socketURL
        let path = url.path
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw SocketError.create(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                _ = memcpy(dst.baseAddress, src.baseAddress, src.count)
            }
        }

        let bindRes = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.bind(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRes < 0 {
            let err = errno
            close(fd)
            throw SocketError.bind(err)
        }
        if Darwin.listen(fd, 32) < 0 {
            let err = errno
            close(fd)
            throw SocketError.listen(err)
        }

        // Make the socket file world-writable for $USER only — matches default.
        chmod(path, S_IRUSR | S_IWUSR)

        // Non-blocking accept so we can drain in a loop on each readiness signal.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        self.serverFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptLoop(onEvent: onEvent)
        }
        let capturedFD = fd
        source.setCancelHandler {
            close(capturedFD)
        }
        source.resume()
        self.acceptSource = source
    }

    private func acceptLoop(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        while serverFD >= 0 {
            let client = accept(serverFD, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                NSLog("AgentMenuBar.HookSocket: accept errno=\(errno)")
                return
            }
            readQueue.async {
                Self.handleClient(client, onEvent: onEvent)
            }
        }
    }

    private static func handleClient(_ fd: Int32,
                                     onEvent: @escaping @Sendable (HookEvent) -> Void) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var accumulated = Data()
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                accumulated.append(buffer, count: n)
                if accumulated.count > 1_048_576 { break } // 1 MB safety cap
            } else if n == 0 {
                break // EOF
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        guard !accumulated.isEmpty else { return }

        // Protocol: one connection = one event payload. Each invocation of the
        // bridge script opens a fresh connection, sends one JSON object, closes.
        // First try to decode the full buffer as a single JSON object (handles
        // both compact and pretty-printed input). If that fails, fall back to
        // newline-delimited mode for callers that batch events.
        if let ev = HookEventDecoder.decode(accumulated) {
            onEvent(ev)
            return
        }

        var line = Data()
        var decoded = 0
        for byte in accumulated {
            if byte == 0x0A {
                if !line.isEmpty, let ev = HookEventDecoder.decode(line) {
                    onEvent(ev)
                    decoded += 1
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty, let ev = HookEventDecoder.decode(line) {
            onEvent(ev)
            decoded += 1
        }
        if decoded == 0 {
            NSLog("AgentMenuBar.HookSocket: failed to decode \(accumulated.count) bytes: \(String(data: accumulated.prefix(200), encoding: .utf8) ?? "<bin>")")
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(Self.socketURL.path)
    }
}
