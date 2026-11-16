import Foundation
import Testing
@testable import ComposerKit

// MARK: - Tokens

private func attributed(_ text: String, tokens: [(String, NSRange)]) -> NSAttributedString {
    let draft = ComposerDraft(
        text: text,
        tokens: tokens.map { PlacedToken(token: ComposerToken(id: $0.0, kind: .file, text: (text as NSString).substring(with: $0.1), value: $0.0), range: $0.1) }
    )
    return TokenText.attributedText(for: draft, base: [:], decoration: { _ in [:] })
}

@Suite struct TokenTextTests {
    // "see @a/b.swift now": token at 4..<14
    let text = attributed("see @a/b.swift now", tokens: [("t1", NSRange(location: 4, length: 10))])

    @Test func placedTokensRoundTrip() {
        let placed = TokenText.placedTokens(in: text)
        #expect(placed.map(\.token.id) == ["t1"])
        #expect(placed.first?.range == NSRange(location: 4, length: 10))
        let draft = TokenText.draft(from: text, attachments: [], selection: NSRange(location: 0, length: 0))
        #expect(draft.tokens == placed)
    }

    @Test func adjacentTokensStaySeparate() {
        let two = attributed("@a@b", tokens: [("x", NSRange(location: 0, length: 2)), ("y", NSRange(location: 2, length: 2))])
        #expect(TokenText.placedTokens(in: two).map(\.token.id) == ["x", "y"])
    }

    @Test func partialEditExpandsToWholeToken() {
        // Backspace at the token's end deletes its last character: expand to the whole token.
        #expect(TokenText.expandedEditRange(NSRange(location: 13, length: 1), in: text) == NSRange(location: 4, length: 10))
        // A selection from the middle of the token into plain text.
        #expect(TokenText.expandedEditRange(NSRange(location: 8, length: 8), in: text) == NSRange(location: 4, length: 12))
        // Plain text and insertion points are untouched.
        #expect(TokenText.expandedEditRange(NSRange(location: 0, length: 3), in: text) == NSRange(location: 0, length: 3))
        #expect(TokenText.expandedEditRange(NSRange(location: 8, length: 0), in: text) == NSRange(location: 8, length: 0))
    }

    @Test func caretSnapsOutOfTokens() {
        let right = TokenText.snappedSelection(from: NSRange(location: 4, length: 0), to: NSRange(location: 5, length: 0), in: text)
        #expect(right == NSRange(location: 14, length: 0))
        let left = TokenText.snappedSelection(from: NSRange(location: 14, length: 0), to: NSRange(location: 13, length: 0), in: text)
        #expect(left == NSRange(location: 4, length: 0))
        let edge = TokenText.snappedSelection(from: NSRange(location: 0, length: 0), to: NSRange(location: 14, length: 0), in: text)
        #expect(edge == NSRange(location: 14, length: 0))
        let selection = TokenText.snappedSelection(from: NSRange(location: 0, length: 0), to: NSRange(location: 2, length: 4), in: text)
        #expect(selection == NSRange(location: 2, length: 12))
    }

    @Test func brokenTokensAreDetected() {
        let mutable = NSMutableAttributedString(attributedString: text)
        #expect(TokenText.brokenTokenRanges(in: mutable).isEmpty)
        mutable.replaceCharacters(in: NSRange(location: 6, length: 1), with: "X")
        #expect(TokenText.brokenTokenRanges(in: mutable) == [NSRange(location: 4, length: 10)])
    }

    @Test func draftValidationDropsStaleTokensAndClampsSelection() {
        var draft = ComposerDraft(
            text: "hello",
            tokens: [PlacedToken(token: ComposerToken(kind: .file, text: "@x", value: "x"), range: NSRange(location: 0, length: 2))],
            selection: NSRange(location: 9, length: 4)
        )
        draft = draft.validated()
        #expect(draft.tokens.isEmpty)
        #expect(draft.selection == NSRange(location: 5, length: 0))
    }

    @Test func mergingKeepsBothDraftsAndShiftsTokens() {
        let token = ComposerToken(kind: .file, text: "@b", value: "b")
        let failed = ComposerDraft(text: "first")
        let current = ComposerDraft(text: "x @b", tokens: [PlacedToken(token: token, range: NSRange(location: 2, length: 2))])
        let merged = ComposerDraft.merging(failed: failed, current: current)
        #expect(merged.text == "first\n\nx @b")
        #expect(merged.tokens.first?.range == NSRange(location: 9, length: 2))
        #expect(merged.validated().tokens.count == 1)
        #expect(ComposerDraft.merging(failed: failed, current: .empty) == failed)
    }

    @Test func emptiness() {
        #expect(ComposerDraft(text: " \n\t").isEmpty)
        #expect(!ComposerDraft(text: "", attachments: [.text("x")]).isEmpty)
    }
}

// MARK: - Attachments

@Suite struct AttachmentTests {
    @Test func limits() {
        var limits = AttachmentLimits()
        limits.maxCount = 2
        limits.maxImageBytes = 10
        limits.maxTotalImageBytes = 15
        var list = AttachmentList(limits: limits)
        let small = ComposerAttachment.image(Data(count: 8), type: .png)
        let big = ComposerAttachment.image(Data(count: 11), type: .png)
        #expect(list.add([small]).isEmpty)
        #expect(list.add([big]) == [.tooLarge(name: big.name, limit: 10)])
        let another = ComposerAttachment.image(Data(count: 8), type: .png)
        #expect(list.add([another]) == [.tooLarge(name: another.name, limit: 15)])
        #expect(list.add([.text("a"), .text("b")]).count == 1)
        #expect(list.count == 2)
        #expect(list.check(.text("c")) == .tooMany(limit: 2))
    }

    @Test func duplicatesAndRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "composer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "notes.md")
        try Data("hello".utf8).write(to: url)
        let file = ComposerAttachment.file(at: url)
        #expect(file.kind == .file && file.byteCount == 5 && file.name == "notes.md")
        #expect(file.mimeType == "text/markdown" || file.mimeType.hasPrefix("text/"))
        var list = AttachmentList()
        list.add([file])
        #expect(list.add([ComposerAttachment.file(at: url)]) == [.duplicate(name: "notes.md")])
        #expect(list.remove(id: file.id)?.id == file.id)
        #expect(list.isEmpty)
        #expect(list.remove(id: "missing") == nil)
    }

    @Test func textAttachmentDescribesItself() {
        let text = ComposerAttachment.text("a\nb\nc")
        #expect(text.name == "Pasted text (3 lines).txt")
        #expect(text.mimeType == "text/plain")
        #expect(text.accessibilityDescription.hasPrefix("Text attachment, Pasted text (3 lines).txt, "))
    }
}

// MARK: - History

@Suite struct PromptHistoryTests {
    @Test func walksAndRestores() {
        var history = PromptHistory(entries: ["one", "two"])
        #expect(!history.isBrowsing)
        #expect(history.next() == nil)
        #expect(history.previous() == .entry("two"))
        #expect(history.previous() == .entry("one"))
        #expect(history.previous() == nil)
        #expect(history.next() == .entry("two"))
        #expect(history.next() == .restoreDraft)
        #expect(!history.isBrowsing)
    }

    @Test func recordSkipsBlanksAndRepeatsAndIsBounded() {
        var history = PromptHistory(capacity: 3)
        for text in ["a", "a", "  ", "b", "c", "d"] { history.record(text) }
        #expect(history.entries == ["b", "c", "d"])
        _ = history.previous()
        history.record("e")
        #expect(!history.isBrowsing)
    }

    @Test func editingEndsBrowsing() {
        var history = PromptHistory(entries: ["x"])
        _ = history.previous()
        history.endBrowsing()
        #expect(history.next() == nil)
    }
}

// MARK: - Send keys

@Suite struct SendKeyPolicyTests {
    @Test func returnKey() {
        let cases: [(SendKey, KeyModifiers, ReturnKeyAction)] = [
            (.returnKey, [], .send(alternate: false)),
            (.returnKey, [.shift], .newline),
            (.returnKey, [.option], .newline),
            (.returnKey, [.control], .newline),
            (.returnKey, [.command], .send(alternate: true)),
            (.commandReturn, [], .newline),
            (.commandReturn, [.shift], .newline),
            (.commandReturn, [.command], .send(alternate: false)),
            (.commandReturn, [.command, .option], .send(alternate: true)),
        ]
        for (sendKey, modifiers, expected) in cases {
            #expect(SendKeyPolicy.action(sendKey: sendKey, modifiers: modifiers, hasMarkedText: false) == expected)
        }
    }

    @Test func compositionNeverSends() {
        for key in SendKey.allCases {
            for modifiers: KeyModifiers in [[], [.command], [.shift], [.command, .option]] {
                #expect(SendKeyPolicy.action(sendKey: key, modifiers: modifiers, hasMarkedText: true) == .inputMethod)
            }
        }
    }

    @Test func deliveries() {
        func delivery(_ alternate: Bool, running: Bool, preferred: ComposerDelivery = .queue, steer: Bool = true) -> ComposerDelivery {
            SendKeyPolicy.delivery(alternate: alternate, isRunning: running, defaultFollowUp: preferred, supportsSteer: steer)
        }
        #expect(delivery(false, running: false) == .now)
        #expect(delivery(true, running: false) == .now)
        #expect(delivery(false, running: true) == .queue)
        #expect(delivery(true, running: true) == .steer)
        #expect(delivery(false, running: true, preferred: .steer) == .steer)
        #expect(delivery(true, running: true, preferred: .steer) == .queue)
        #expect(delivery(true, running: true, steer: false) == .queue)
        #expect(SendKeyPolicy.shortcutLabel(sendKey: .returnKey, alternate: true) == "⌘⏎")
    }

    @Test func codeLikeText() {
        #expect(!CodeLikeText.isCodeLike("Please refactor the parser so it is easier to read."))
        #expect(!CodeLikeText.isCodeLike("hi"))
        #expect(CodeLikeText.isCodeLike("```\nlet x = 1\n```"))
        #expect(CodeLikeText.isCodeLike("if (a && b) { foo(x[0]); return y; }"))
        #expect(CodeLikeText.isCodeLike("def f():\n    return 1\n    pass"))
    }
}
