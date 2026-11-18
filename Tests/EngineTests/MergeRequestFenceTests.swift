import BelloCore
import Foundation
import Synchronization
import Testing

@testable import Engine

/// A forge transport whose merge-request read waits at a gate until the test releases it.
final class GatedForgeTransport: ForgeTransport {
    let inner = FixtureForgeTransport()
    private let state = Mutex<(armed: Bool, parked: CheckedContinuation<Void, Never>?)>((false, nil))

    func arm() { state.withLock { $0.armed = true } }
    var isParked: Bool { state.withLock { $0.parked != nil } }

    func release() {
        let parked = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.armed = false
            defer { state.parked = nil }
            return state.parked
        }
        parked?.resume()
    }

    func send(_ request: ForgeRequest) async throws -> ForgeResponse {
        if request.url.absoluteString == "\(GitLabFixtures.api)/merge_requests/42" {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let park = state.withLock { state -> Bool in
                    guard state.armed else { return false }
                    state.parked = continuation
                    return true
                }
                if !park { continuation.resume() }
            }
        }
        return try await inner.send(request)
    }
}

/// Deep review 1, C8: unwatching fences a poll whose GitLab request is already out.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct MergeRequestFenceTests {
    let thread = SessionID("ses_mr")

    struct Setup {
        let service: MergeRequestService
        let clock: ManualWallClock
        let host: FakeMergeRequestHost
        let transport: GatedForgeTransport
        let store: ProjectionStore
    }

    /// A watched MR with its baseline taken, then a change that would wake the thread, with the next read gated.
    func setUp() async throws -> Setup {
        let clock = ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000))
        let transport = GatedForgeTransport()
        let store = try ProjectionStore(location: .inMemory)
        let service = MergeRequestService(
            store: store, clock: clock, transport: transport, tokens: GitLabFixtures.tokens(), baseInterval: 120, maxBackoff: 1_800,
            autoPoll: false)
        let host = FakeMergeRequestHost()
        service.host = host
        await service.start()
        _ = try await service.saveInstance(baseURL: GitLabFixtures.instance.baseURL, token: nil)
        GitLabFixtures.install(transport.inner, mr: GitLabFixtures.mr())
        try await service.setWatching(GitLabFixtures.ref, for: thread, true)
        await service.waitForFetches()
        await service.pollDue()
        #expect(service.watch(thread, GitLabFixtures.ref.url)?.baseline != nil)
        GitLabFixtures.install(transport.inner, mr: GitLabFixtures.mr(pipelineStatus: "failed"), jobs: GitLabFixtures.jobs([("unit", "failed")]))
        transport.arm()
        clock.advance(by: 120)
        return Setup(service: service, clock: clock, host: host, transport: transport, store: store)
    }

    /// Starts the due poll and returns once its read is parked at the gate.
    func pollParked(_ setup: Setup) async throws -> Task<Void, Never> {
        let service = setup.service
        let poll = Task { await service.pollDue() }
        try await waitUntil("read parked") { setup.transport.isParked }
        return poll
    }

    @Test func aDelayedSuccessAfterUnwatchNeitherWakesNorRestoresTheWatch() async throws {
        let setup = try await setUp()
        let poll = try await pollParked(setup)
        try await setup.service.setWatching(GitLabFixtures.ref, for: thread, false)
        setup.transport.release()
        await poll.value
        #expect(setup.host.wakes.isEmpty, "no wake after consent was withdrawn")
        #expect(setup.service.watch(thread, GitLabFixtures.ref.url) == nil)
        #expect(setup.service.nextPollDate(thread, GitLabFixtures.ref.url) == nil)
        #expect(try await setup.store.mergeRequestWatches().isEmpty, "nothing persisted for the old watch")
        setup.service.shutdown()
    }

    @Test func aDelayedFailureAfterUnwatchIsDropped() async throws {
        let setup = try await setUp()
        setup.transport.inner.set("\(GitLabFixtures.api)/merge_requests/42", [ForgeResponse(status: 599)])
        let poll = try await pollParked(setup)
        try await setup.service.setWatching(GitLabFixtures.ref, for: thread, false)
        setup.transport.release()
        await poll.value
        #expect(setup.service.watch(thread, GitLabFixtures.ref.url) == nil)
        #expect(setup.service.nextPollDate(thread, GitLabFixtures.ref.url) == nil)
        #expect(try await setup.store.mergeRequestWatches().isEmpty)
        setup.service.shutdown()
    }

    @Test func removingAndReaddingTheSameURLIgnoresTheOldPoll() async throws {
        let setup = try await setUp()
        let poll = try await pollParked(setup)
        try await setup.service.setWatching(GitLabFixtures.ref, for: thread, false)
        try await setup.service.setWatching(GitLabFixtures.ref, for: thread, true)
        let armed = setup.clock.now()
        setup.transport.release()
        await poll.value
        #expect(setup.host.wakes.isEmpty)
        let record = try #require(setup.service.watch(thread, GitLabFixtures.ref.url))
        #expect(record.baseline == nil, "the new watch takes its own baseline")
        #expect(setup.service.nextPollDate(thread, GitLabFixtures.ref.url) == armed, "the new watch's first poll is not pushed back")
        setup.service.shutdown()
    }

    @Test func archivingWhileTheReadIsOutIsHonouredAfterIt() async throws {
        let setup = try await setUp()
        let poll = try await pollParked(setup)
        setup.host.pauses[thread] = .archived
        setup.transport.release()
        await poll.value
        #expect(setup.host.wakes.isEmpty, "the pause is evaluated after the fetch")
        #expect(setup.service.watch(thread, GitLabFixtures.ref.url) != nil, "still watched; it resumes when unarchived")
        setup.service.shutdown()
    }
}
