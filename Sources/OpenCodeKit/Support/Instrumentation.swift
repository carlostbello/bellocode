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
    case let error as OpenCodeError: error.description
    case let error as ServerSupervisorError: error.description
    case let error as TimeoutError: error.description
    case let error as SSEParser.Failure: "\(error)"
    case let error as URLError: "network error \(error.code.rawValue)"
    case is DecodingError: "decoding error: \(OpenCodeClient.describe(error))"
    case is CancellationError: "cancelled"
    default: "\(type(of: error))"
    }
}
