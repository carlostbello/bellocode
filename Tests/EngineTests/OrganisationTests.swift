import BelloCore
import Foundation
import GRDB
import MockOpenCode
import Testing

@testable import Engine

@Suite("Thread sections and wake rules")
struct ThreadSectionTests {
    private func t(_ ms: Double) -> Timestamp { Fixtures.t(ms) }
    private let hour = 3_600_000.0

    private func input(
        _ id: String, created: Double = 1, busy: Double? = nil, idle: Double? = nil, seen: Double? = nil,
        status: SessionStatus = .idle, since: Double? = nil, _ org: ThreadOrganisation = .none
    ) -> ThreadSectionInput {
        ThreadSectionInput(
            sessionID: SessionID(id), created: t(created), busySince: busy.map(t), idleAt: idle.map(t), seenAt: seen.map(t),
            status: status, statusSince: since.map(t), organisation: org)
    }

    @Test func everyStateLandsInItsSection() {
        let now = t(10 * hour)
        let inputs = [
            input("pinned", busy: 5, status: .running, ThreadOrganisation(pinned: true)),
            input("active", idle: 4),
            input("working", busy: 9, status: .running),
            input("snoozed", ThreadOrganisation(snoozedUntil: t(20 * hour), snoozedAt: t(1))),
            input("settled", ThreadOrganisation(settled: true, settledAt: t(2))),
        ]
        let sections = ThreadSections.derive(inputs, now: now)
        #expect(sections[.pinned] == ["pinned"])
        #expect(sections[.active] == ["active"])
        #expect(sections[.working] == ["working"])
        #expect(sections[.snoozed] == ["snoozed"])
        #expect(sections[.settled] == ["settled"])
        #expect(ThreadSection.allCases.allSatisfy { sections[$0] != nil }, "empty sections are present")
    }

    @Test func snoozeWakesAtItsTimeOrWhenItNeedsTheUser() {
        let snooze = ThreadOrganisation(snoozedUntil: t(100), snoozedAt: t(50))
        // Before its time: hidden.
        #expect(ThreadSections.section(input("a", snooze), now: t(99)) == .snoozed)
        // Its time arrives (injected clock).
        #expect(ThreadSections.wakeReason(input("a", snooze), now: t(100)) == .timeArrived)
        #expect(ThreadSections.section(input("a", snooze), now: t(100)) == .active)
        // Blocked on the user: back at once.
        #expect(ThreadSections.wakeReason(input("a", status: .awaitingApproval, snooze), now: t(60)) == .needsUser)
        // A failure after the snooze wakes it; one from before does not.
        #expect(ThreadSections.wakeReason(input("a", status: .failed, since: 70, snooze), now: t(80)) == .failed)
        #expect(ThreadSections.wakeReason(input("a", status: .failed, since: 40, snooze), now: t(80)) == nil)
        // A new run (a user message) after the snooze wakes it into Working; a run already going does not.
        #expect(ThreadSections.section(input("a", busy: 70, status: .running, snooze), now: t(80)) == .working)
        #expect(ThreadSections.section(input("a", busy: 40, status: .running, snooze), now: t(80)) == .snoozed)
        // A completion alone does not wake a snooze.
        #expect(ThreadSections.wakeReason(input("a", status: .finishedUnread, since: 70, snooze), now: t(80)) == nil)
    }

    @Test func settledUnsettlesOnNewActivityThatNeedsTheUser() {
        let settled = ThreadOrganisation(settled: true, settledAt: t(50))
        #expect(ThreadSections.section(input("s", status: .idle, settled), now: t(1_000)) == .settled)
        #expect(ThreadSections.wakeReason(input("s", status: .awaitingAnswer, settled), now: t(60)) == .needsUser)
        #expect(ThreadSections.wakeReason(input("s", status: .finishedUnread, since: 70, settled), now: t(80)) == .finished)
        #expect(ThreadSections.wakeReason(input("s", status: .finishedUnread, since: 40, settled), now: t(80)) == nil)
        #expect(ThreadSections.wakeReason(input("s", busy: 70, status: .running, settled), now: t(80)) == .newTurn)
    }

    @Test func orderingIsStableAndNeverReshufflesWhileAgentsWork() {
        // Working: by run start, oldest first; a new run joins at the end.
        let working = [input("late", busy: 30, status: .running), input("early", busy: 10, status: .running)]
        #expect(ThreadSections.derive(working, now: t(100))[.working] == ["early", "late"])
        let more = working + [input("newest", busy: 50, status: .running)]
        #expect(ThreadSections.derive(more, now: t(100))[.working] == ["early", "late", "newest"])
        // Active: newest created first unless moved by hand.
        let active = [input("old", created: 1), input("new", created: 5), input("moved", created: 2, ThreadOrganisation(sortKey: 10))]
        #expect(ThreadSections.derive(active, now: t(100))[.active] == ["moved", "new", "old"])
        // Snoozed by wake time; settled by settle time, newest first.
        let shelves = [
            input("z2", ThreadOrganisation(snoozedUntil: t(300), snoozedAt: t(1))),
            input("z1", ThreadOrganisation(snoozedUntil: t(200), snoozedAt: t(1))),
            input("s1", ThreadOrganisation(settled: true, settledAt: t(5))),
            input("s2", ThreadOrganisation(settled: true, settledAt: t(9))),
        ]
        let derived = ThreadSections.derive(shelves, now: t(100))
        #expect(derived[.snoozed] == ["z1", "z2"])
        #expect(derived[.settled] == ["s2", "s1"])
    }

    @Test func autoSettleAfterTheConfiguredTimeWithPerThreadNever() {
        let rules = OrganisationRules(autoSettleAfterHours: 8)
        let finished = input("f", idle: 1 * hour, seen: 2 * hour, status: .idle)
        #expect(!ThreadSections.shouldAutoSettle(finished, rules: rules, now: t(9 * hour)))
        #expect(ThreadSections.shouldAutoSettle(finished, rules: rules, now: t(10 * hour)))
        #expect(ThreadSections.autoSettleDeadline(finished, rules: rules) == t(10 * hour))
        // Never: per thread, pinned, unread, running and blocked threads stay.
        #expect(!ThreadSections.shouldAutoSettle(input("n", idle: 1, seen: 1, ThreadOrganisation(neverAutoSettle: true)), rules: rules, now: t(100 * hour)))
        #expect(!ThreadSections.shouldAutoSettle(input("p", idle: 1, seen: 1, ThreadOrganisation(pinned: true)), rules: rules, now: t(100 * hour)))
        #expect(!ThreadSections.shouldAutoSettle(input("u", idle: 1, status: .finishedUnread), rules: rules, now: t(100 * hour)))
        #expect(!ThreadSections.shouldAutoSettle(input("r", busy: 1, status: .running), rules: rules, now: t(100 * hour)))
        #expect(!ThreadSections.shouldAutoSettle(finished, rules: OrganisationRules(autoSettleAfterHours: nil), now: t(1_000 * hour)))
        // A thread that never ran (no finished turn) is never settled, however old.
        #expect(!ThreadSections.shouldAutoSettle(input("new", created: 1, status: .idle), rules: rules, now: t(1_000 * hour)))
    }

    @Test func pendingChangesWakeToTheTopAndAutoSettle() {
        let now = t(100 * hour)
        let changes = ThreadSections.pendingChanges(
            [
                input("woken", ThreadOrganisation(snoozedUntil: t(50 * hour), snoozedAt: t(1))),
                input("old", idle: 1, seen: 1),
                input("quiet", ThreadOrganisation(snoozedUntil: t(200 * hour), snoozedAt: t(1))),
                input("pinnedStale", ThreadOrganisation(pinned: true, settled: true, settledAt: t(1))),
            ], rules: OrganisationRules(autoSettleAfterHours: 24), now: now)
        #expect(changes["woken"]?.snoozedUntil == nil)
        #expect(changes["woken"]?.sortKey == now.milliseconds, "a woken thread returns to the top of Active")
        #expect(changes["old"]?.settled == true)
        #expect(changes["old"]?.settledAt == now)
        #expect(changes["quiet"] == nil)
        #expect(changes["pinnedStale"]?.settled == false)
        let next = ThreadSections.nextDeadline(
            [input("quiet", ThreadOrganisation(snoozedUntil: t(200 * hour), snoozedAt: t(1))), input("f", idle: 90 * hour, seen: 95 * hour)],
            rules: OrganisationRules(autoSettleAfterHours: 24), now: now)
        #expect(next == t(119 * hour), "the earliest of a snooze end and an auto-settle")
    }

    @Test func transitionsClearConflictingState() {
        let now = t(500)
        var org = ThreadOrganisation(pinned: true)
        org.apply(.settle, now: now)
        #expect(org == ThreadOrganisation(settled: true, settledAt: now))
        org.apply(.snooze(until: t(900)), now: now)
        #expect(org.snoozedUntil == t(900) && org.snoozedAt == now && !org.settled)
        org.apply(.pin, now: now)
        #expect(org.pinned && org.snoozedUntil == nil)
        org.apply(.unsettle, now: now)
        #expect(!org.pinned == false, "unsettle keeps a pin")
        org.apply(.activate, now: now)
        #expect(!org.pinned && !org.settled && org.snoozedUntil == nil)
    }

    @Test func snoozePresets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        // Monday 16 Nov 2026, 10:20.
        let morning = date(2026, 11, 16, 10, 20)
        #expect(SnoozePreset.laterToday.date(from: morning, calendar: calendar) == date(2026, 11, 16, 14))
        #expect(SnoozePreset.tomorrow.date(from: morning, calendar: calendar) == date(2026, 11, 17, 9))
        #expect(SnoozePreset.nextWeek.date(from: morning, calendar: calendar) == date(2026, 11, 23, 9))
        // 16:10: 18:00 is sooner than 19:10 and more than an hour away.
        #expect(SnoozePreset.laterToday.date(from: date(2026, 11, 16, 16, 10), calendar: calendar) == date(2026, 11, 16, 18))
        // 20:30: three hours on is past 22:00, so tomorrow morning (never "later today" at midnight).
        #expect(SnoozePreset.laterToday.date(from: date(2026, 11, 16, 20, 30), calendar: calendar) == date(2026, 11, 17, 9))
        // Late evening: tomorrow morning.
        #expect(SnoozePreset.laterToday.date(from: date(2026, 11, 16, 22), calendar: calendar) == date(2026, 11, 17, 9))
        // Monday before nine: next week is a week on, not today.
        #expect(SnoozePreset.nextWeek.date(from: date(2026, 11, 16, 7), calendar: calendar) == date(2026, 11, 23, 9))
        // Sunday: next week is tomorrow.
        #expect(SnoozePreset.nextWeek.date(from: date(2026, 11, 22, 20), calendar: calendar) == date(2026, 11, 23, 9))
    }
}

@Suite("Thread organisation in the engine", .serialized)
@MainActor
struct EngineOrganisationTests {
    func makeEngine(_ url: URL) throws -> Engine {
        var configuration = EngineConfiguration(server: .dynamic { nil }, store: .file(url))
        configuration.writeInterval = .milliseconds(5)
        return try Engine(configuration: configuration)
    }

    @Test func organisationPersistsAcrossRelaunchAndWakesOnTheEngineTimer() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "projection.sqlite")
        do {
            let store = try ProjectionStore(location: .file(url))
            var batch = StoreBatch()
            batch.sessions = [Fixtures.session("ses_a"), Fixtures.session("ses_b"), Fixtures.session("ses_c")]
            try await store.apply(batch)
        }
        let engine = try makeEngine(url)
        await engine.start()
        let now = Timestamp.now
        engine.organise(["ses_a"], .pin, now: now)
        engine.organise(["ses_b"], .snooze(until: Timestamp(milliseconds: now.milliseconds + 400)), now: now)
        engine.organise(["ses_c"], .setNeverAutoSettle(true), now: now)
        #expect(engine.root.organisation["ses_a"]?.pinned == true, "applied at once")
        #expect(engine.root.attention.items.isEmpty)
        // The snooze ends on the engine's own timer, and the wake is persisted.
        try await waitUntil("woken", timeout: .seconds(5)) { engine.root.organisation["ses_b"]?.snoozedUntil == nil }
        #expect(engine.root.organisation["ses_b"]?.sortKey != nil)
        await engine.flush()
        await engine.stop()

        let relaunched = try makeEngine(url)
        await relaunched.start()
        #expect(relaunched.root.organisation["ses_a"]?.pinned == true)
        #expect(relaunched.root.organisation["ses_c"]?.neverAutoSettle == true)
        #expect(relaunched.root.organisation["ses_b"]?.snoozedUntil == nil)
        await relaunched.stop()
    }

    @Test func rulesPersistAndMarkViewedClearsMarkedUnread() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "projection.sqlite")
        let engine = try makeEngine(url)
        await engine.start()
        engine.setOrganisationRules(OrganisationRules(autoSettleAfterHours: 8))
        engine.organise(["ses_x"], .setMarkedUnread(true))
        #expect(engine.root.organisation["ses_x"]?.markedUnread == true)
        // Let the engine's actor apply the mark before viewing (commands from the main actor are not ordered).
        try await Task.sleep(for: .milliseconds(100))
        try? await engine.markViewed("ses_x")
        try await waitUntil("viewed") { engine.root.organisation["ses_x"]?.markedUnread != true }
        await engine.flush()
        await engine.stop()
        let relaunched = try makeEngine(url)
        await relaunched.start()
        #expect(relaunched.root.organisationRules.autoSettleAfterHours == 8)
        await relaunched.stop()
    }

    @Test func migrationV4KeepsExistingThreadState() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "projection.sqlite")
        // A database as M1 wrote it (up to v3), with a draft and a pin.
        let queue = try DatabaseQueue(path: url.path)
        try ProjectionSchema.migrator.migrate(queue, upTo: "v3-app-terminals")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO app_thread (session_id, draft, pinned, settled) VALUES ('ses_old', 'half a thought', 1, 0)")
        }
        try queue.close()
        let store = try ProjectionStore(location: .file(url))
        #expect(try await store.appliedMigrations().last == "v4-thread-organisation")
        let states = try await store.threadUIStates()
        #expect(states.count == 1)
        #expect(states[0].draft == "half a thought")
        #expect(states[0].pinned)
        #expect(states[0].sortKey == nil && states[0].settledAt == nil && !states[0].neverAutoSettle && !states[0].markedUnread)
        // The new columns round-trip.
        var batch = StoreBatch()
        var state = states[0]
        state.organisation = ThreadOrganisation(
            pinned: false, sortKey: 42.5, snoozedUntil: Fixtures.t(9), snoozedAt: Fixtures.t(3), settled: false,
            settledAt: nil, neverAutoSettle: true, markedUnread: true)
        batch.threadUI = [state]
        try await store.apply(batch)
        #expect(try await store.threadUIStates().first?.organisation == state.organisation)
    }

    @Test func decodesThreadUIStateWrittenBeforeTheNewFields() throws {
        let json = #"{"sessionID":"ses_1","draft":"x","pinned":true,"settled":false,"scrollOffset":0}"#
        let state = try JSONDecoder().decode(ThreadUIState.self, from: Data(json.utf8))
        #expect(state.pinned && state.draft == "x" && state.organisation.sortKey == nil)
    }
}

@Suite("Palette matching, frecency and search mapping")
struct NavigationLogicTests {
    @Test func fuzzyPrefersPrefixesWordStartsAndRuns() throws {
        #expect(FuzzyMatcher.match("nt", in: "New Thread") != nil)
        #expect(FuzzyMatcher.match("xyz", in: "New Thread") == nil)
        let wordStart = try #require(FuzzyMatcher.match("nt", in: "New Thread"))
        let midWord = try #require(FuzzyMatcher.match("nt", in: "Continue editing"))
        #expect(wordStart.score > midWord.score)
        #expect(wordStart.positions == [0, 4])
        let prefix = try #require(FuzzyMatcher.match("term", in: "Terminal"))
        let inner = try #require(FuzzyMatcher.match("term", in: "Show the determined plan"))
        #expect(prefix.score > inner.score)
        // Case and diacritics do not matter; every word must match, in any order.
        #expect(FuzzyMatcher.match("CAFE", in: "café menu") != nil)
        #expect(FuzzyMatcher.match("test fix", in: "Fix flaky tests") != nil)
        #expect(FuzzyMatcher.match("test fax", in: "Fix flaky tests") == nil)
        // camelCase and path components are word starts.
        let path = try #require(FuzzyMatcher.match("pv", in: "Sources/ParserView.swift"))
        #expect(path.positions == [8, 14])
    }

    @Test func frecencyRanksRecentAndFrequentAndRemembersPicks() {
        let day = 86_400_000.0
        let now = Fixtures.t(100 * day)
        var index = FrecencyIndex()
        for offset in 0..<5 { index.record("thread:often", now: Fixtures.t(now.milliseconds - Double(offset) * day)) }
        index.record("thread:once-today", now: now)
        index.record("thread:old", now: Fixtures.t(now.milliseconds - 60 * day))
        #expect(index.score("thread:often", now: now) > index.score("thread:once-today", now: now))
        #expect(index.score("thread:once-today", now: now) > index.score("thread:old", now: now))
        #expect(index.top(prefix: "thread:", limit: 2, now: now) == ["thread:often", "thread:once-today"])
        // The pick for a query is remembered for three weeks.
        index.record("command:newThread", query: "nt", now: now)
        #expect(index.pick(for: " NT ", now: now) == "command:newThread")
        #expect(index.pick(for: "nt", now: Fixtures.t(now.milliseconds + 22 * day)) == nil)
    }

    @Test func frecencyIsBounded() {
        var index = FrecencyIndex()
        for i in 0..<(FrecencyIndex.entryLimit + 50) { index.record("k\(i)", query: "q\(i)", now: Fixtures.t(Double(i))) }
        #expect(index.entries.count == FrecencyIndex.entryLimit)
        #expect(index.picks.count <= FrecencyIndex.pickLimit)
    }

    @Test func searchGroupsByTopLevelThreadInRankOrder() {
        var parent = Fixtures.session("ses_parent", title: "Parser refactor")
        parent.created = Fixtures.t(1)
        let child = Fixtures.session("ses_child", parent: "ses_parent", title: "explore")
        let other = Fixtures.session("ses_other", title: "Docs")
        let open = String(MessageSearch.openMarker)
        let close = String(MessageSearch.closeMarker)
        let hits = [
            SearchHit(messageID: "m1", sessionID: "ses_other", snippet: "the \(open)parser\(close) [docs]", created: Fixtures.t(5)),
            SearchHit(messageID: "m2", sessionID: "ses_child", snippet: "\(open)parser\(close)\n\n  split", created: Fixtures.t(9)),
            SearchHit(messageID: "m3", sessionID: "ses_parent", snippet: "x", created: Fixtures.t(7)),
            SearchHit(messageID: "m4", sessionID: "ses_gone", snippet: "y", created: Fixtures.t(7)),
        ]
        let groups = MessageSearch.group(hits, sessions: ["ses_parent": parent, "ses_child": child, "ses_other": other])
        #expect(groups.map(\.sessionID) == ["ses_other", "ses_parent"])
        #expect(groups[1].hits.map(\.messageID) == ["m2", "m3"], "a sub-agent's hit is grouped under its thread")
        #expect(groups[1].hits[0].sessionID == "ses_child")
        #expect(groups[1].newest == Fixtures.t(9))
        #expect(groups[0].hits[0].snippet == SearchSnippet(text: "the parser [docs]", highlights: [4..<10]), "brackets in text stay text")
        #expect(groups[1].hits[0].snippet.text == "parser split", "whitespace collapses to one line")
    }
}

@Suite("Notification policy")
struct NotificationPolicyTests {
    private func item(_ id: String, _ status: SessionStatus, since: Double = 1, project: String = "p1") -> SessionAttention {
        SessionAttention(sessionID: SessionID(id), projectID: ProjectID(project), status: status, since: Fixtures.t(since))
    }

    private func context(active: Bool = false, front: SessionID? = nil, _ settings: NotificationSettings = NotificationSettings()) -> NotificationPolicy.Context {
        NotificationPolicy.Context(appIsActive: active, frontmostThread: front, settings: settings, projectDirectory: { "/dir/\($0.rawValue)" })
    }

    @Test func firstEvaluationLearnsThenNewEntriesFireOnce() {
        var policy = NotificationPolicy()
        #expect(policy.evaluate(AttentionSummary(items: [item("a", .awaitingApproval)]), context: context()).isEmpty, "nothing at launch")
        let summary = AttentionSummary(items: [item("a", .awaitingApproval), item("b", .failed)])
        let fired = policy.evaluate(summary, context: context())
        #expect(fired.map(\.kind) == [.failure])
        // The same summary again (another event, a token, a resync) fires nothing.
        for _ in 0..<50 { #expect(policy.evaluate(summary, context: context()).isEmpty) }
        // A new blocker on the same thread (a later request) is a new event.
        let later = AttentionSummary(items: [item("a", .awaitingApproval, since: 9), item("b", .failed)])
        #expect(policy.evaluate(later, context: context()).map(\.kind) == [.approval])
    }

    @Test func foregroundModesAndMutes() {
        var policy = NotificationPolicy()
        _ = policy.evaluate(.empty, context: context())
        // Active app: a blocker on another thread notifies; on the thread on screen it does not; completions wait for
        // the app to be in the background.
        let fired = policy.evaluate(
            AttentionSummary(items: [item("shown", .awaitingAnswer), item("other", .awaitingApproval), item("done", .finishedUnread)]),
            context: context(active: true, front: "shown"))
        #expect(fired.map(\.sessionID) == ["other"])
        var blockers = NotificationPolicy()
        _ = blockers.evaluate(.empty, context: context())
        let onlyBlockers = NotificationSettings(mode: .blockersOnly)
        #expect(blockers.evaluate(AttentionSummary(items: [item("c", .finishedUnread), item("f", .failed)]), context: context(onlyBlockers)).map(\.kind) == [.failure])
        var off = NotificationPolicy()
        _ = off.evaluate(.empty, context: context())
        #expect(off.evaluate(AttentionSummary(items: [item("x", .awaitingApproval)]), context: context(NotificationSettings(mode: .none))).isEmpty)
        var muted = NotificationPolicy()
        _ = muted.evaluate(.empty, context: context())
        let settings = NotificationSettings(mutedProjects: ["/dir/quiet"])
        let result = muted.evaluate(
            AttentionSummary(items: [item("q", .awaitingApproval, project: "quiet"), item("l", .awaitingApproval, project: "loud")]),
            context: context(settings))
        #expect(result.map(\.sessionID) == ["l"])
    }

    @Test func burstsBecomeOneSummary() {
        var policy = NotificationPolicy()
        _ = policy.evaluate(.empty, context: context())
        let items = (0..<6).map { item("s\($0)", .failed) }
        let fired = policy.evaluate(AttentionSummary(items: items), context: context())
        #expect(fired.count == 1)
        #expect(fired[0].kind == .summary && fired[0].count == 6)
    }

    @Test func inlineApprovalOnlyForShortSingleOperations() {
        func request(_ action: String, _ resources: [String]) -> PermissionRequest {
            PermissionRequest(id: "per_1", sessionID: "ses_1", action: action, resources: resources, received: Fixtures.t(1))
        }
        let short = NotificationActionSafety.describe(request("shell", ["swift build"]))
        #expect(short.text == "Run: swift build" && short.allowsInlineApproval)
        #expect(!NotificationActionSafety.describe(request("edit", ["a.swift", "b.swift"])).allowsInlineApproval)
        #expect(!NotificationActionSafety.describe(request("shell", [String(repeating: "x", count: 200)])).allowsInlineApproval)
        #expect(!NotificationActionSafety.describe(request("shell", ["echo a\nrm -rf /"])).allowsInlineApproval)
    }
}
