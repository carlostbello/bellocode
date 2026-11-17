import Foundation
import Synchronization

/// One frame received from a PTY WebSocket.
public enum PTYSocketMessage: Sendable, Hashable {
    /// Raw PTY output bytes.
    case output(Data)
    /// A decoded control message.
    case control(PTYControlMessage)
}

/// Why a PTY WebSocket ended.
public enum PTYSocketClose: Sendable, Hashable {
    /// Close 1000 (after `exited`, or our own close).
    case normal
    /// 4404 "terminal unavailable": another controller holds the PTY (or it is gone).
    case unavailable
    /// The connection failed or dropped (`code` is the WebSocket close code, 0 when none was received).
    case failed(code: Int, reason: String)
    /// The HTTP upgrade was refused with this status (404 when the PTY no longer exists).
    case rejected(status: Int)
}

/// The transport under a PTY attachment. Production uses `URLSessionPTYSocket`; tests may inject fakes.
public protocol PTYSocket: Sendable {
    /// The next frame. Throws `PTYSocketClosed` when the socket ends; honours task cancellation.
    func receive() async throws -> PTYSocketMessage
    /// Sends a binary frame. Frames are sent in call order.
    func send(_ frame: Data)
    /// Closes with 1000. Idempotent.
    func close()
}

/// Thrown by `PTYSocket.receive()` when the socket has ended.
public struct PTYSocketClosed: Error, Sendable, Hashable {
    public var reason: PTYSocketClose
    public init(_ reason: PTYSocketClose) { self.reason = reason }
}

/// `URLSessionWebSocketTask`-backed PTY socket. Frames up to 64 MiB (the replay frame carries up to the server's
/// 2 MiB ring; headroom for larger rings). A ping every `pingInterval` detects dead connections (sleep, network
/// change), since an idle shell may send nothing for hours.
public final class URLSessionPTYSocket: PTYSocket {
    private let task: URLSessionWebSocketTask
    private let pinger = Mutex<Task<Void, Never>?>(nil)
    private let closed = Mutex(false)

    /// Shared session for PTY sockets: ephemeral, no cache or cookies.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    public init(request: URLRequest, session: URLSession = URLSessionPTYSocket.session, pingInterval: Duration = .seconds(15)) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20
        task.resume()
        let task = self.task
        let ping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pingInterval)
                if Task.isCancelled { return }
                task.sendPing { error in
                    if error != nil { task.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
        pinger.withLock { $0 = ping }
    }

    deinit { close() }

    public func receive() async throws -> PTYSocketMessage {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await withTaskCancellationHandler {
                    try await task.receive()
                } onCancel: { [task] in
                    task.cancel(with: .normalClosure, reason: nil)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw PTYSocketClosed(closeReason(error))
            }
            switch message {
            case .data(let data):
                return .output(data)
            case .string(let text):
                if let control = PTYControlMessage.decode(text) { return .control(control) }
            @unknown default:
                continue
            }
        }
    }

    public func send(_ frame: Data) {
        task.send(.data(frame)) { _ in }
    }

    public func close() {
        let first = closed.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        pinger.withLock { task in
            task?.cancel()
            task = nil
        }
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func closeReason(_ error: any Error) -> PTYSocketClose {
        let code = task.closeCode.rawValue
        if code == 1000 { return .normal }
        if code == 4404 { return .unavailable }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status >= 400 { return .rejected(status: status) }
        let reason = task.closeReason.map { String(decoding: $0.prefix(120), as: UTF8.self) }
            ?? (error as? URLError).map { "network error \($0.code.rawValue)" } ?? "\(type(of: error))"
        return .failed(code: code, reason: reason)
    }
}
