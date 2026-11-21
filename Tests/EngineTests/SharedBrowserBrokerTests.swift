import ContainerKit
import Foundation
import OpenCodeKit
import SecretKit
import Synchronization
import Testing

@testable import Engine

// MARK: - Tab gate: serialisation, lease, takeover, admission

@Suite("Shared browser tab gate", .timeLimit(.minutes(3)))
struct BrowserTabGateTests {
    /// Waits (bounded by yields, not time) until `condition` holds.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<20_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// N26: a call refused for the queue limits neither takes nor renews a shared tab's lease.
    @Test func aRefusedCallDoesNotStealTheLease() async throws {
        let now = Mutex(ContinuousClock.now)
        var limits = BrowserTabGate.Limits()
        limits.maxActive = 1
        limits.maxQueued = 0
        let gate = BrowserTabGate(limits: limits, now: { now.withLock { $0 } })
        // A drives the shared tab, then its lease goes idle; meanwhile another call fills the only active slot.
        let first = try await gate.acquire(tab: "shared", session: "A", shared: true)
        await gate.release(first)
        let busy = try await gate.acquire(tab: "other", session: "C", shared: false)
        now.withLock { $0 += .seconds(90) }
        await #expect(throws: BrowserTabGate.Busy.overloaded) { _ = try await gate.acquire(tab: "shared", session: "B", shared: true) }
        #expect(await gate.driver(of: "shared") != "B", "B was refused: it holds no lease")
        await gate.release(busy)
        // A can drive the tab again (B's refused call did not make B the driver).
        let again = try await gate.acquire(tab: "shared", session: "A", shared: true)
        await gate.release(again)
    }

    /// N26: per-tab and per-thread display bookkeeping stays bounded.
    @Test func displayBookkeepingIsBounded() async throws {
        let gate = BrowserTabGate()
        for index in 0..<(BrowserTabGate.maxTracked * 3) {
            await gate.setName("thread \(index)", for: "ses_\(index)")
            let ticket = try await gate.acquire(tab: "tab-\(index)", session: "ses_\(index)", shared: false)
            await gate.release(ticket)
        }
        #expect(await gate.activity().count <= BrowserTabGate.maxTracked)
        #expect(await gate.trackedNames <= BrowserTabGate.maxTracked)
    }

    @Test func callsToOneTabRunOneAtATimeInOrder() async throws {
        let gate = BrowserTabGate()
        let first = try await gate.acquire(tab: "bc-a-main", session: "a", shared: false)
        let order = Mutex<[String]>([])
        let second = Task {
            let ticket = try await gate.acquire(tab: "bc-a-main", session: "a", shared: false)
            order.withLock { $0.append("second") }
            await gate.release(ticket)
        }
        #expect(await eventually { await gate.counts.queued == 1 })
        order.withLock { $0.append("first-done") }
        await gate.release(first)
        try await second.value
        #expect(order.withLock { $0 } == ["first-done", "second"])
    }

    @Test func differentTabsRunInParallel() async throws {
        let gate = BrowserTabGate()
        let a = try await gate.acquire(tab: "bc-a-main", session: "a", shared: false)
        let b = try await gate.acquire(tab: "bc-b-main", session: "b", shared: false)
        #expect(await gate.counts.running == 2)
        await gate.release(a)
        await gate.release(b)
    }

    @Test func aSharedTabHasOneDriverAndOthersGetBusy() async throws {
        let now = Mutex(ContinuousClock.now)
        let gate = BrowserTabGate(now: { now.withLock { $0 } })
        await gate.setName("Fix login", for: "a")
        let ticket = try await gate.acquire(tab: "bc-a-main", session: "a", shared: true)
        await gate.release(ticket)
        await #expect(throws: BrowserTabGate.Busy.driven(by: "Fix login", tab: "bc-a-main")) {
            _ = try await gate.acquire(tab: "bc-a-main", session: "b", shared: true)
        }
        // The lease lapses after a quiet minute; then the other thread can drive.
        now.withLock { $0 = $0 + .seconds(61) }
        let other = try await gate.acquire(tab: "bc-a-main", session: "b", shared: true)
        #expect(await gate.driver(of: "bc-a-main") == "b")
        await gate.release(other)
        await gate.yield(tab: "bc-a-main", session: "b")
        #expect(await gate.driver(of: "bc-a-main") == nil)
    }

    @Test func takeOverFailsWaitersRefusesNewCallsAndGiveBackRestores() async throws {
        let gate = BrowserTabGate()
        let running = try await gate.acquire(tab: "bc-a-main", session: "a", shared: false)
        let waiter = Task { try await gate.acquire(tab: "bc-a-main", session: "a", shared: false) }
        #expect(await eventually { await gate.counts.queued == 1 })
        let affected = await gate.takeOver("bc-a-main")
        #expect(affected == ["a"])
        await #expect(throws: BrowserTabGate.Busy.humanControl(tab: "bc-a-main")) { _ = try await waiter.value }
        await #expect(throws: BrowserTabGate.Busy.humanControl(tab: "bc-a-main")) {
            _ = try await gate.acquire(tab: "bc-a-main", session: "b", shared: false)
        }
        // Other tabs keep working during a single-tab takeover.
        let other = try await gate.acquire(tab: "bc-b-main", session: "b", shared: false)
        await gate.release(other)
        await gate.release(running)
        await gate.giveBack("bc-a-main")
        let after = try await gate.acquire(tab: "bc-a-main", session: "a", shared: false)
        await gate.release(after)
        await gate.takeOver("*")
        await #expect(throws: BrowserTabGate.Busy.humanControl(tab: "*")) { _ = try await gate.acquire(tab: "bc-b-main", session: "b", shared: false) }
        await gate.giveBack("*")
        #expect(await gate.isHumanControlled("bc-b-main") == false)
    }

    @Test func admissionIsBoundedAndPerThread() async throws {
        var limits = BrowserTabGate.Limits()
        limits.maxActive = 1
        limits.maxQueued = 3
        limits.maxQueuedPerThread = 2
        let gate = BrowserTabGate(limits: limits)
        let held = try await gate.acquire(tab: "t0", session: "a", shared: false)
        var waiting: [Task<BrowserTabGate.Ticket, any Error>] = []
        // One at a time: separate tasks reach the actor in either order, and the order queued is the order served.
        for index in 1...2 {
            waiting.append(Task { try await gate.acquire(tab: "t\(index)", session: "a", shared: false) })
            #expect(await eventually { await gate.counts.queued == index })
        }
        await #expect(throws: BrowserTabGate.Busy.threadQueueFull) { _ = try await gate.acquire(tab: "t9", session: "a", shared: false) }
        waiting.append(Task { try await gate.acquire(tab: "t3", session: "b", shared: false) })
        #expect(await eventually { await gate.counts.queued == 3 })
        await #expect(throws: BrowserTabGate.Busy.overloaded) { _ = try await gate.acquire(tab: "t4", session: "c", shared: false) }
        // Fairness: a was served last, so b's waiting call goes before a's queued ones.
        await gate.release(held)
        let fair = try await waiting[2].value
        #expect(fair.session == "b")
        await gate.release(fair)
        let next = try await waiting[0].value
        #expect(next.tab == "t1")
        await gate.release(next)
        await gate.release(try await waiting[1].value)
    }

    @Test func aRestartFailsEverythingInFlight() async throws {
        let gate = BrowserTabGate()
        let running = try await gate.acquire(tab: "t", session: "a", shared: false)
        let waiter = Task { try await gate.acquire(tab: "t", session: "b", shared: false) }
        #expect(await eventually { await gate.counts.queued == 1 })
        _ = await gate.newGeneration()
        await #expect(throws: BrowserTabGate.Busy.restarted) { _ = try await waiter.value }
        #expect(await gate.isCurrent(running) == false, "a result from the old browser is dropped")
    }
}

// MARK: - Call policy: tab groups per thread

@Suite("Shared browser call policy")
struct BrowserCallPolicyTests {
    let binding = BrowserBinding(sessionID: "ses_a", project: "/p/atlas", group: "bc-aaaa0001")

    func plan(_ tool: String, _ args: [String: JSONValue], shared: Set<String> = [], byMe: Set<String> = [], numeric: [Int: String] = [:]) -> BrowserCallPolicy.Plan {
        BrowserCallPolicy.plan(tool: tool, arguments: .object(args), context: .init(
            binding: binding, sharedWithMe: shared, sharedByMe: byMe, numeric: numeric, ownerName: { $0.hasPrefix("bc-bbbb") ? "Other thread" : nil }))
    }

    @Test func callsWithoutATabGoToTheThreadsDefaultTabInItsGroup() {
        guard case .forward(let tool, let args, let tab, let shared, let ensure, _) = plan("navigate", ["url": .string("https://atlas.bc:5173/")]) else {
            Issue.record("refused")
            return
        }
        #expect(tool == "navigate" && tab == "bc-aaaa0001-main" && !shared && ensure)
        #expect(args["tab"]?.stringValue == "bc-aaaa0001-main")
    }

    @Test func newTabsLandInTheGroupWithPrefixedIDs() {
        guard case .forward(_, let args, let tab, _, _, let remember) = plan("tabs", ["action": .string("new"), "id": .string("docs"), "url": .string("https://x")]) else {
            Issue.record("refused")
            return
        }
        #expect(tab == "bc-aaaa0001-docs" && remember == "bc-aaaa0001-docs")
        #expect(args["group"]?.stringValue == "bc-aaaa0001")
        guard case .forward(_, let unnamed, _, _, _, _) = plan("tabs", ["action": .string("new"), "id": .string("Bad ID!")]) else { return }
        #expect(unnamed["id"]?.stringValue == "bc-aaaa0001-t2")
    }

    @Test func listingIsLimitedToTheThreadsGroup() {
        guard case .forward(_, let args, _, _, _, _) = plan("tabs", ["action": .string("list"), "group": .string("bc-bbbb0002")]) else { return }
        #expect(args["group"]?.stringValue == "bc-aaaa0001")
    }

    @Test func anotherThreadsTabIsRefusedNamingItsOwner() {
        guard case .refuse(let message) = plan("click", ["tab": .string("bc-bbbb0002-main"), "ref": .string("e1")]) else {
            Issue.record("allowed")
            return
        }
        #expect(message.contains("Other thread"))
        guard case .refuse = plan("tabs", ["action": .string("close"), "tabs": .array([.string("bc-aaaa0001-main"), .string("bc-bbbb0002-main")])]) else {
            Issue.record("bulk close of a foreign tab allowed")
            return
        }
    }

    @Test func aDeliberatelySharedTabIsUsableWithTheLease() {
        guard case .forward(_, _, let tab, let shared, let ensure, _) = plan("snapshot", ["tab": .string("bc-bbbb0002-main")], shared: ["bc-bbbb0002-main"]) else {
            Issue.record("refused")
            return
        }
        #expect(tab == "bc-bbbb0002-main" && shared && !ensure)
        guard case .refuse = plan("tabs", ["action": .string("close"), "tab": .string("bc-bbbb0002-main")], shared: ["bc-bbbb0002-main"]) else {
            Issue.record("closing a shared tab allowed")
            return
        }
        guard case .forward(_, _, _, let ownShared, _, _) = plan("click", ["ref": .string("e2")], byMe: ["bc-aaaa0001-main"]) else { return }
        #expect(ownShared, "the owner also takes the lease on a tab it shared")
    }

    @Test func numericTabsAreTranslatedOrRefused() {
        guard case .forward(_, let args, _, _, _, _) = plan("click", ["tab": .number(777), "ref": .string("e1")], numeric: [777: "bc-aaaa0001-main"]) else {
            Issue.record("refused")
            return
        }
        #expect(args["tab"]?.stringValue == "bc-aaaa0001-main", "string IDs get browse's reservation")
        guard case .refuse = plan("click", ["tab": .number(999)]) else {
            Issue.record("unknown numeric allowed")
            return
        }
    }

    @Test func globalToolsAreNotOffered() {
        guard case .refuse = plan("settings", ["set": .object([:])]) else {
            Issue.record("settings allowed")
            return
        }
        let tools = SharedBrowserBroker.agentTools(from: [
            ClientMCPTool(name: "settings", description: "", inputSchema: .object([:])),
            ClientMCPTool(name: "navigate", description: "Go", inputSchema: .object([:])),
        ])
        #expect(tools.map(\.name) == ["navigate", SharedBrowserBroker.releaseTool])
    }

    @Test func tabIDsAreLearnedFromResults() {
        let text = #"{"tab":777331874,"url":"http://x/","id":"bc-aaaa0001-main","group":"bc-aaaa0001"}"#
        #expect(BrowserCallPolicy.learnTabIDs(from: text) == [777331874: "bc-aaaa0001-main"])
    }

    @Test func namingIsStableAndValid() {
        let group = BrowserNaming.group(sessionID: "ses_123")
        #expect(group == BrowserNaming.group(sessionID: "ses_123"))
        #expect(group != BrowserNaming.group(sessionID: "ses_124"))
        #expect(BrowserNaming.isValidTabID(BrowserNaming.mainTab(group: group)))
        #expect(!BrowserNaming.isValidTabID("1abc") && !BrowserNaming.isValidTabID("ABC"))
        #expect(BrowserNaming.projectLabel(directory: "/Users/x/Repos/Atlas Web", taken: []) == "atlas-web")
        #expect(BrowserNaming.projectLabel(directory: "/a/atlas", taken: ["atlas"]) == "atlas-2")
        #expect(BrowserNaming.projectLabel(directory: "/a/123", taken: []) == "p-123")
    }
}

// MARK: - Routing table

@Suite("Shared browser routing")
struct BrowserRoutingTests {
    let projects = [
        BrowserRouteProject(directory: "/r/atlas", label: "atlas", projectKey: "k1", workspaceContainer: "bellocode-ws-shared", workspaceRunning: true,
                            services: ["api": [8080, 9090], "db": [5432]]),
        BrowserRouteProject(directory: "/r/zen", label: "zen", projectKey: "k2", workspaceContainer: "bellocode-ws-k2", workspaceRunning: false,
                            services: ["db": [5432]]),
    ]

    @Test func projectNamesReachTheWorkspaceOnItsLoopback() {
        let resolved = BrowserRouteTable.resolve(HostPort(host: "atlas.bc", port: 5173), projects: projects)
        #expect(resolved == .target(BrowserRouteTarget(kind: .workspace, project: "/r/atlas", container: "bellocode-ws-shared", host: "127.0.0.1", port: 5173)))
    }

    @Test func serviceNamesReachTheServiceFromTheWorkspaceOnTheProjectNetwork() {
        let resolved = BrowserRouteTable.resolve(HostPort(host: "api.atlas.bc", port: 443), projects: projects)
        #expect(resolved == .target(BrowserRouteTarget(kind: .service, project: "/r/atlas", container: "bellocode-ws-shared", host: "api", port: 8080)),
                "no project network is ever joined by the browser's gateway")
        if case .target(let explicit) = BrowserRouteTable.resolve(HostPort(host: "api.atlas.bc", port: 9090), projects: projects) {
            #expect(explicit.port == 9090)
        } else { Issue.record("declared port refused") }
    }

    @Test func unknownOrUnavailableNamesAreRefused() {
        for (host, port) in [("nope.bc", 80), ("zen.bc", 3000), ("db.zen.bc", 443), ("web.atlas.bc", 443), ("api.atlas.bc", 1234), ("a.b.atlas.bc", 443), ("bc", 443)] {
            guard case .refuse = BrowserRouteTable.resolve(HostPort(host: host, port: port), projects: projects) else {
                Issue.record("\(host):\(port) was routed")
                continue
            }
        }
    }

    @Test func thePreviewScopeReachesRoutesOnly() async {
        struct Internet: EgressRouter { func route(scheme: String, destination: HostPort, scope: String) async -> EgressRoute { .internet } }
        let router = BrowserEgressRouter(table: { destination, _ in destination.host == "atlas.bc" ? .dial(EgressDial(endpoint: HostPort(host: "127.0.0.1", port: 1), terminatesTLS: true)) : nil },
                                         fallback: Internet(), routesOnlyScopes: ["preview"])
        guard case .refuse = await router.route(scheme: "https", destination: HostPort(host: "example.com", port: 443), scope: "preview") else {
            Issue.record("preview reached the internet")
            return
        }
        guard case .internet = await router.route(scheme: "https", destination: HostPort(host: "example.com", port: 443), scope: "browser") else {
            Issue.record("browser refused the internet")
            return
        }
        guard case .dial(let dial) = await router.route(scheme: "https", destination: HostPort(host: "atlas.bc", port: 5173), scope: "preview") else {
            Issue.record("route refused")
            return
        }
        #expect(dial.terminatesTLS)
        guard case .refuse = await router.route(scheme: "https", destination: HostPort(host: "other.bc", port: 443), scope: "browser") else {
            Issue.record("unknown .bc reached the internet")
            return
        }
    }
}

// MARK: - Broker: approvals, attribution, groups, restarts (fake browse mcp)

/// An in-memory `browse mcp`: answers initialize, tools/list and tools/call, recording the calls.
final class CallLog: Sendable {
    let entries = Mutex<[(tool: String, args: JSONValue)]>([])
    func append(_ entry: (tool: String, args: JSONValue)) { entries.withLock { $0.append(entry) } }
    var all: [(tool: String, args: JSONValue)] { entries.withLock { $0 } }
}

final class FakeBrowseTransport: BrowseMCPTransport {
    let calls: CallLog
    /// Tools whose replies never come (a call still running in the browser).
    let held: Set<String>
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(calls: CallLog = CallLog(), held: Set<String> = []) {
        self.calls = calls
        self.held = held
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
    }

    func lines() -> AsyncThrowingStream<Data, any Error> { stream }

    func send(_ line: Data) async throws {
        guard let message = try? JSONValue.parse(line), let method = message["method"]?.stringValue else { return }
        guard let id = message["id"] else { return }
        var result: JSONValue = .object([:])
        switch method {
        case "tools/list":
            result = .object(["tools": .array(["navigate", "snapshot", "click", "tabs", "settings"].map {
                .object(["name": .string($0), "description": .string($0), "inputSchema": .object(["type": .string("object")])])
            })])
        case "tools/call":
            let tool = message["params"]?["name"]?.stringValue ?? ""
            let args = message["params"]?["arguments"] ?? .null
            calls.append((tool, args))
            if held.contains(tool) { return }
            let tab = args["tab"]?.stringValue ?? args["id"]?.stringValue ?? ""
            result = .object(["content": .array([
                .object(["type": .string("text"), "text": .string("{\"tab\":\(abs(tab.hashValue % 100000)),\"id\":\"\(tab)\",\"ok\":true}")]),
                .object(["type": .string("image"), "data": .string("iVBORw0KGgo="), "mimeType": .string("image/png")]),
            ])])
        default: break
        }
        let reply = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        continuation.yield(try JSONEncoder().encode(reply))
    }

    func close() async { continuation.finish() }
}

actor FakeSharedBrowserHost: SharedBrowserHost {
    var approved: Set<String> = []
    var requested: [String] = []
    var bindings: [String: BrowserBinding] = [:]
    var sharesWithMe: [String: Set<String>] = [:]
    var begins = 0
    var gen = 0
    nonisolated let calls = CallLog()
    var held: Set<String> = []

    func hold(_ tool: String) { held.insert(tool) }

    func approve(_ directory: String) { approved.insert(directory) }
    func setGeneration(_ value: Int) { gen = value }
    func share(_ tab: String, with session: String) { sharesWithMe[session, default: []].insert(tab) }

    func access(session: String, directory: String) async -> BrowserAccess { approved.contains(directory) ? .allowed : .needsApproval }
    func requestAccess(session: String, directory: String) async -> ClientMCPResult {
        requested.append(session)
        return ClientMCPResult(text: "asked")
    }
    func binding(session: String, directory: String) async -> BrowserBinding {
        if let existing = bindings[session] { return existing }
        let made = BrowserBinding(sessionID: session, project: directory, group: BrowserNaming.group(sessionID: session))
        bindings[session] = made
        return made
    }
    func save(_ binding: BrowserBinding) async { bindings[binding.sessionID] = binding }
    func shares(session: String) async -> (withMe: Set<String>, byMe: Set<String>, owners: [String: String]) {
        var owners: [String: String] = [:]
        for binding in bindings.values { for tab in binding.tabs { owners[tab] = "thread \(binding.sessionID)" } }
        let byMe = Set(sharesWithMe.values.flatMap { $0 }.filter { bindings[session]?.owns($0) == true })
        return (sharesWithMe[session] ?? [], byMe, owners)
    }
    func beginCall() async throws { begins += 1 }
    func endCall() async {}
    func makeTransport() async throws -> any BrowseMCPTransport { FakeBrowseTransport(calls: calls, held: held) }
    func generation() async -> Int { gen }
    func threadTitle(session: String) async -> String { "thread \(session)" }
}

@Suite("Shared browser broker", .timeLimit(.minutes(3)))
struct SharedBrowserBrokerTests {
    func call(_ broker: SharedBrowserBroker, _ tool: String, _ args: [String: JSONValue], session: String?, directory: String = "/p/atlas") async -> ClientMCPResult {
        await broker.call(ClientMCPCall(tool: tool, arguments: .object(args), sessionID: session, directory: directory))
    }

    @Test func theServerNeedsThePersonsApprovalFirst() async {
        let host = FakeSharedBrowserHost()
        let broker = SharedBrowserBroker(host: host)
        #expect(await broker.tools(directory: "/p/atlas").map(\.name) == [SharedBrowserBroker.requestAccessTool])
        let refused = await call(broker, "navigate", ["url": .string("https://x")], session: "ses_a")
        #expect(refused.isError && refused.text.contains("approval"))
        let asked = await call(broker, SharedBrowserBroker.requestAccessTool, [:], session: "ses_a")
        #expect(asked.text == "asked")
        #expect(await host.requested == ["ses_a"])
        #expect(await host.begins == 0, "nothing starts the browser before approval")
        await host.approve("/p/atlas")
        let tools = await broker.tools(directory: "/p/atlas").map(\.name)
        #expect(tools.contains("navigate") && !tools.contains("settings") && tools.contains(SharedBrowserBroker.releaseTool))
    }

    @Test func unattributedCallsAreRefused() async {
        let host = FakeSharedBrowserHost()
        await host.approve("/p/atlas")
        let broker = SharedBrowserBroker(host: host)
        let result = await call(broker, "navigate", ["url": .string("https://x")], session: nil)
        #expect(result.isError && result.text.contains("which thread"))
    }

    @Test func twoThreadsGetTheirOwnGroupsAndCannotTouchEachOthersTabs() async {
        let host = FakeSharedBrowserHost()
        await host.approve("/p/atlas")
        let broker = SharedBrowserBroker(host: host)
        let a = await call(broker, "navigate", ["url": .string("https://atlas.bc:5173/")], session: "ses_a")
        let b = await call(broker, "navigate", ["url": .string("https://atlas.bc:5173/")], session: "ses_b")
        #expect(!a.isError && !b.isError)
        #expect(a.images.count == 1, "image blocks pass through")
        let groupA = BrowserNaming.group(sessionID: "ses_a"), groupB = BrowserNaming.group(sessionID: "ses_b")
        let calls = host.calls.all
        #expect(calls.contains { $0.tool == "tabs" && $0.args["id"]?.stringValue == "\(groupA)-main" && $0.args["group"]?.stringValue == groupA })
        #expect(calls.contains { $0.tool == "navigate" && $0.args["tab"]?.stringValue == "\(groupB)-main" })
        let poke = await call(broker, "click", ["tab": .string("\(groupA)-main"), "ref": .string("e1")], session: "ses_b")
        #expect(poke.isError && poke.text.contains("thread ses_a"))
    }

    @Test func aSharedTabIsUsableAndItsDriverHoldsIt() async {
        let host = FakeSharedBrowserHost()
        await host.approve("/p/atlas")
        let broker = SharedBrowserBroker(host: host)
        _ = await call(broker, "navigate", ["url": .string("https://x")], session: "ses_a")
        let tab = "\(BrowserNaming.group(sessionID: "ses_a"))-main"
        await host.share(tab, with: "ses_b")
        let used = await call(broker, "snapshot", ["tab": .string(tab)], session: "ses_b")
        #expect(!used.isError, "\(used.text)")
        let busy = await call(broker, "click", ["tab": .string(tab), "ref": .string("e1")], session: "ses_a")
        #expect(busy.isError && busy.text.hasPrefix("Busy") && busy.text.contains("thread ses_b"), "\(busy.text)")
        _ = await call(broker, SharedBrowserBroker.releaseTool, ["tab": .string(tab)], session: "ses_b")
        let back = await call(broker, "click", ["tab": .string(tab), "ref": .string("e1")], session: "ses_a")
        #expect(!back.isError, "\(back.text)")
    }

    @Test func aRestartIsToldToEveryThreadThatUsedTheBrowser() async {
        let host = FakeSharedBrowserHost()
        await host.approve("/p/atlas")
        let broker = SharedBrowserBroker(host: host)
        _ = await call(broker, "navigate", ["url": .string("https://x")], session: "ses_a")
        await host.setGeneration(1)
        await broker.browserRestarted(generation: 1, reason: "The shared Chrome stopped unexpectedly.")
        let next = await call(broker, "snapshot", [:], session: "ses_a")
        #expect(next.text.hasPrefix("[BelloCode] The shared Chrome stopped unexpectedly."))
        let again = await call(broker, "snapshot", [:], session: "ses_a")
        #expect(!again.text.hasPrefix("[BelloCode]"), "told once")
        // The default tab is created again in the new browser.
        let ensures = host.calls.all.filter { $0.tool == "tabs" && $0.args["action"]?.stringValue == "new" }.count
        #expect(ensures == 2)
    }

    /// R22: a call already sent to the browser is cancelled, and Take Over returns (so the person gets control) only
    /// once it has settled; the agent is told its call was cut short.
    @Test func takeOverCancelsAndWaitsOutDispatchedCalls() async throws {
        let host = FakeSharedBrowserHost()
        await host.approve("/p/atlas")
        await host.hold("click")
        let broker = SharedBrowserBroker(host: host)
        let tab = "\(BrowserNaming.group(sessionID: "ses_a"))-main"
        _ = await call(broker, "navigate", ["url": .string("https://x")], session: "ses_a")
        let inFlight = Task { await self.call(broker, "click", ["ref": .string("e1")], session: "ses_a") }
        var dispatched = false
        for _ in 0..<20_000 {
            if host.calls.all.contains(where: { $0.tool == "click" }) { dispatched = true; break }
            await Task.yield()
        }
        try #require(dispatched, "the click reached the browser")
        #expect(await broker.gate.isIdle(tab) == false)
        let settled = await broker.takeOver("*")
        #expect(settled)
        #expect(await broker.gate.isIdle("*"), "control is handed over only after the dispatched call settled")
        let result = await inFlight.value
        #expect(result.isError && result.text.contains("took over"), "\(result.text)")
        await broker.gate.giveBack("*")
    }

    @Test func takeOverMakesAgentCallsBusy() async {
        let host = FakeSharedBrowserHost()
        await host.approve("/p/atlas")
        let broker = SharedBrowserBroker(host: host)
        await broker.gate.takeOver("*")
        let result = await call(broker, "navigate", ["url": .string("https://x")], session: "ses_a")
        #expect(result.isError && result.text.contains("taken over"))
        await broker.gate.giveBack("*")
        #expect(!(await call(broker, "navigate", ["url": .string("https://x")], session: "ses_a")).isError)
    }
}

@Suite("Pooled browse MCP client", .timeLimit(.minutes(3)))
struct BrowseMCPClientTests {
    /// Replies out of order: the second request is answered first.
    final class Reordering: BrowseMCPTransport {
        let held = Mutex<[Data]>([])
        private let stream: AsyncThrowingStream<Data, any Error>
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        init() { (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self) }
        func lines() -> AsyncThrowingStream<Data, any Error> { stream }
        func send(_ line: Data) async throws {
            guard let message = try? JSONValue.parse(line), let id = message["id"], let method = message["method"]?.stringValue else { return }
            let text = method == "tools/call" ? (message["params"]?["arguments"]?["n"]?.numberValue).map { "n\(Int($0))" } ?? "" : ""
            let result: JSONValue = method == "tools/call" ? .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
                : method == "tools/list" ? .object(["tools": .array([])]) : .object([:])
            let reply = try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            if method == "tools/call" {
                let ready = held.withLock { held -> [Data] in
                    held.append(reply)
                    if held.count == 2 { defer { held = [] }; return held.reversed() }
                    return []
                }
                for item in ready { continuation.yield(item) }
            } else {
                continuation.yield(reply)
            }
        }
        func close() async { continuation.finish() }
    }

    @Test func repliesAreMatchedByID() async throws {
        let client = BrowseMCPClient(transport: Reordering())
        _ = try await client.start()
        async let one = client.call("x", arguments: .object(["n": .number(1)]))
        async let two = client.call("x", arguments: .object(["n": .number(2)]))
        let (a, b) = try await (one, two)
        #expect(a.text == "n1" && b.text == "n2")
    }

    @Test func aClosedProcessFailsPendingCalls() async throws {
        let transport = Reordering()
        let client = BrowseMCPClient(transport: transport)
        _ = try await client.start()
        let pending = Task { try await client.call("x", arguments: .object(["n": .number(1)])) }
        for _ in 0..<1000 { await Task.yield() }
        await transport.close()
        await #expect(throws: BrowseMCPClient.Failure.closed) { _ = try await pending.value }
    }
}
