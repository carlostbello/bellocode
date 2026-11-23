import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import BelloCodeApp

/// AV10: GitLab text that is ready only after an await (Add to Agent Context, Send to Agent) goes to the composer that
/// was shown when the action started, or nowhere: never to the thread the person switched to meanwhile.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct MergeRequestComposerTargetTests {
    @Test func aTargetBoundToOneThreadNeverInsertsIntoAnother() async throws {
        _ = NSApplication.shared
        let engine = try Engine(configuration: EngineConfiguration(server: .dynamic { nil }, store: .inMemory))
        let first = engine.openThread(SessionID("ses_private_mr"))
        let second = engine.openThread(SessionID("ses_other_project"))
        defer {
            first.close()
            second.close()
        }
        var intoFirst: [String] = []
        var intoSecond: [String] = []
        let a = ThreadSurfaceContext(engine: engine, directory: "/tmp/a", projectName: "a", thread: first)
        a.onInsertIntoComposer = { intoFirst.append($0) }
        let b = ThreadSurfaceContext(engine: engine, directory: "/tmp/b", projectName: "b", thread: second)
        b.onInsertIntoComposer = { intoSecond.append($0) }
        let surfaces = MergeRequestSurfaces()
        surfaces.display(a)
        let target = try #require(surfaces.composerTarget())
        // The person switches threads while the token is read.
        surfaces.display(b)
        #expect(target.insert("private discussion") == false)
        #expect(intoFirst.isEmpty && intoSecond.isEmpty, "nothing landed in either composer")
        // Bound now, to the thread on screen: it lands there.
        #expect(try #require(surfaces.composerTarget()).insert("for b"))
        #expect(intoSecond == ["for b"])
        // Back to the first thread with a new context: the stale target still refuses.
        let again = ThreadSurfaceContext(engine: engine, directory: "/tmp/a", projectName: "a", thread: first)
        again.onInsertIntoComposer = { intoFirst.append($0) }
        surfaces.display(again)
        #expect(target.insert("late") == false)
        #expect(intoFirst.isEmpty)
        // No composer shown: no target.
        surfaces.display(nil)
        #expect(surfaces.composerTarget() == nil)
    }
}
