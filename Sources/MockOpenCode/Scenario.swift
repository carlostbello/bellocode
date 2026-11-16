import Foundation

/// Everything the mock serves at start: data, catalog, scripts and the defaults new turns use.
///
/// A scenario is a plain value. The server copies it at ``MockOpenCodeServer/init(scenario:options:)`` and mutates its
/// own copy, so one scenario can seed many servers.
public struct Scenario: Sendable {
    /// The directory used when a request names none (the real server uses its working directory).
    public var defaultDirectory: String
    public var projects: [MockProject]
    /// Sessions in creation order.
    public var sessions: [MockSession]
    /// Messages per session id, oldest first.
    public var messages: [String: [MockMessage]]
    public var catalog: MockCatalog
    /// Integrations offered for login (`GET /api/integration`), with the catalog entries each unlocks.
    public var integrations: [MockIntegration] = MockIntegration.standard
    /// Named scripts. A prompt whose text contains `#script:<name>` plays that script.
    public var scripts: [String: TurnScript]
    /// Played for a prompt that names no script and has nothing queued with ``MockOpenCodeServer/enqueueScript(_:for:)``.
    public var defaultScript: TurnScript
    /// Agent and model used for new turns when the session names none.
    public var defaultAgent: String
    public var defaultModel: ModelRef
    /// Seeds identifiers and any randomness, so runs are repeatable.
    public var seed: UInt64
    /// Epoch milliseconds the virtual clock starts at.
    public var startTime: Int64

    public init(
        defaultDirectory: String = "/tmp/mock-project", projects: [MockProject] = [], sessions: [MockSession] = [],
        messages: [String: [MockMessage]] = [:], catalog: MockCatalog = .standard, scripts: [String: TurnScript] = [:],
        defaultScript: TurnScript = .greeting, defaultAgent: String = "build", defaultModel: ModelRef = .bigPickle,
        seed: UInt64 = 1, startTime: Int64 = 1_794_000_000_000
    ) {
        self.defaultDirectory = defaultDirectory
        self.projects = projects
        self.sessions = sessions
        self.messages = messages
        self.catalog = catalog
        self.scripts = scripts
        self.defaultScript = defaultScript
        self.defaultAgent = defaultAgent
        self.defaultModel = defaultModel
        self.seed = seed
        self.startTime = startTime
    }

    /// One git project at ``defaultDirectory`` and no sessions.
    public static func empty(directory: String = "/tmp/mock-project", seed: UInt64 = 1) -> Scenario {
        var scenario = Scenario(defaultDirectory: directory, seed: seed)
        var ids = IdentifierGenerator(seed: seed ^ 0x5EED)
        scenario.projects = [MockProject(id: ids.hash40(), directory: directory, time: scenario.startTime)]
        scenario.scripts = TurnScript.builtIns
        return scenario
    }

    /// A small hand-made scenario for demos: two projects, a few sessions with history, one child session.
    public static func demo(seed: UInt64 = 1) -> Scenario {
        FixtureGenerator(seed: seed).workspace(projectCount: 2, sessionCount: 6, messagesPerSession: 8)
    }

    /// The large standard workload: `sessionCount` sessions across `projectCount` projects, plus one session with
    /// `largeSessionMessages` mixed messages (see ``FixtureGenerator``).
    public static func large(
        seed: UInt64 = 42, projectCount: Int = 8, sessionCount: Int = 200, largeSessionMessages: Int = 10_000
    ) -> Scenario {
        let generator = FixtureGenerator(seed: seed)
        var scenario = generator.workspace(
            projectCount: projectCount, sessionCount: sessionCount, messagesPerSession: 6)
        generator.addLargeSession(to: &scenario, messageCount: largeSessionMessages)
        return scenario
    }
}

extension MockCatalog {
    /// The pinned opencode 2.3.0 built-in agents and free models, plus a fictional second provider.
    public static let standard: MockCatalog = {
        func array(_ text: String) -> [JSONValue] {
            (try? JSONValue.parse(text))?.arrayValue ?? []
        }
        return MockCatalog(
            providers: array(DefaultCatalogJSON.providers), models: array(DefaultCatalogJSON.models),
            agents: array(DefaultCatalogJSON.agents), defaultModelID: "big-pickle")
    }()
}

/// Options that are about the server process rather than the data it serves.
public struct MockServerOptions: Sendable {
    public enum Clock: Sendable, Equatable {
        /// Sleeps are real; timestamps are wall-clock milliseconds.
        case realTime
        /// Sleeps return at once and advance a virtual clock that starts at ``Scenario/startTime``. Timestamps and
        /// ids are then fully deterministic, and scripted turns finish as fast as the machine can run them.
        case virtual
    }

    /// Basic-auth password for user `opencode`. `nil` disables auth.
    public var password: String?
    public var clock: Clock
    /// Interval for `: heartbeat` comments on event streams. `nil` sends only the one after `server.connected`.
    public var heartbeatInterval: Duration?
    /// Frames a single event-stream subscriber may have waiting before the mock drops that connection, like the real
    /// server's 4,096-frame queue. Overflow ends the connection; it is never silent loss.
    public var subscriberQueueLimit: Int
    /// Reported by `GET /api/info`.
    public var version: String

    public init(
        password: String? = "mock-password", clock: Clock = .realTime, heartbeatInterval: Duration? = .seconds(15),
        subscriberQueueLimit: Int = 4096, version: String = "2.3.0"
    ) {
        self.password = password
        self.clock = clock
        self.heartbeatInterval = heartbeatInterval
        self.subscriberQueueLimit = subscriberQueueLimit
        self.version = version
    }

    /// Virtual clock, no periodic heartbeats: what tests want.
    public static let testing = MockServerOptions(clock: .virtual, heartbeatInterval: nil)
}
