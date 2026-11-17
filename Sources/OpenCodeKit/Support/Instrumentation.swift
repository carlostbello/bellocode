import Foundation
import os

/// Signposts and logging for OpenCodeKit. Never log content: no message text, no credentials, no request bodies.
enum Instrumentation {
    static let subsystem = "app.bellocode.OpenCodeKit"
    static let events = OSSignposter(subsystem: subsystem, category: "EventHub")
    static let server = OSSignposter(subsystem: subsystem, category: "ServerSupervisor")
    static let http = OSSignposter(subsystem: subsystem, category: "HTTP")
    static let serverLog = Logger(subsystem: subsystem, category: "ServerSupervisor")
    static let eventLog = Logger(subsystem: subsystem, category: "EventHub")
}

/// A content-free, credential-free description of an error, safe to show in state and logs.
func describeError(_ error: any Error) -> String {
    switch error {
    // Never the server's message text: it is arbitrary and can echo request content.
    case let error as OpenCodeError: error.logSummary
    case let error as ServerSupervisorError: error.description
    case let error as TimeoutError: error.description
    case let error as SSEParser.Failure: "\(error)"
    case let error as URLError: "network error \(error.code.rawValue)"
    // Coding paths can contain server-chosen keys (file paths in maps): only the kind of failure.
    case is DecodingError: "decoding error"
    case is CancellationError: "cancelled"
    default: "\(type(of: error))"
    }
}
