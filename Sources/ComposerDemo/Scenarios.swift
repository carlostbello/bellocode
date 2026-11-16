import AppKit
import ComposerKit
import Foundation

/// Scripted scenarios. Each starts with a fresh composer and records failures on the harness.
@MainActor
struct Scenarios {
    let h: Harness

    init(_ harness: Harness) { h = harness }

    var all: [(String, () async -> Void)] {
        [
            ("ime-japanese", imeJapanese), ("ime-chinese", imeChinese), ("emoji", emoji), ("send-keys", sendKeys),
            ("send-failure", sendFailure), ("running", running), ("mention-undo", mentionUndo),
            ("slash-command", slashCommand), ("paste", paste), ("history", history), ("growth", growth),
            ("thread-switch", threadSwitch), ("spellcheck", spellcheck), ("escape", escape),
            ("accessibility", accessibility), ("latency", latency), ("snapshots", snapshots),
        ]
    }

    private func host(_ key: String = "thread-1", prompts: [String] = []) -> FakeHost {
        let host = FakeHost(key: key, prompts: prompts)
        h.composer.host = host
        return host
    }

    // MARK: Input methods

    /// Japanese romaji composition: Return while composing never sends; the committed text sends on the next Return.
    func imeJapanese() async {
        let host = host()
        let tv = h.textView
        tv.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.setMarkedText("日本", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.expect(tv.hasMarkedText(), "composition is active")
        await h.press(.up)
        h.expect(tv.hasMarkedText() && h.text == "日本", "Up during composition leaves the composition alone")
        // The input method consumes Return to commit; it reaches us only as the committed text.
        tv.insertText("日本", replacementRange: tv.markedRange())
        h.expect(!tv.hasMarkedText(), "composition committed")
        h.expectEqual(host.submissions.count, 0, "committing does not send")
        await h.type("語を")
        tv.setMarkedText("はなす", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // A Return that reaches the view while composing (an input method that passes it through) confirms only.
        await h.press(.returnKey)
        h.expect(!tv.hasMarkedText(), "Return during composition confirms it")
        h.expectEqual(h.text, "日本語をはなす", "Return during composition inserts no newline")
        await h.pause(60)
        h.expectEqual(host.submissions.count, 0, "Return during composition never sends")
        await h.press(.returnKey)
        await h.pause(60)
        h.expectEqual(host.submissions.map(\.text), ["日本語をはなす"], "Return after composition sends")
    }

    /// Pinyin composition with a trigger character inside the marked text: no completion popover while composing.
    func imeChinese() async {
        let host = host()
        let tv = h.textView
        await h.type("请看 ")
        for step in ["n", "ni", "nih", "niha", "nihao"] {
            tv.setMarkedText(step, selectedRange: NSRange(location: step.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        tv.setMarkedText("@你好", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await h.pause(80)
        h.expect(!h.composer.completion.isOpen, "no completion while composing, even with @ in the marked text")
        await h.press(.down)
        h.expect(tv.hasMarkedText(), "Down while composing belongs to the input method")
        tv.insertText("你好", replacementRange: tv.markedRange())
        h.expectEqual(h.text, "请看 你好", "pinyin commit")
        await h.press(.returnKey)
        await h.pause(60)
        h.expectEqual(host.submissions.first?.text, "请看 你好", "sends the committed Chinese text")
    }

    func emoji() async {
        _ = host()
        await h.type("ship it 👩‍💻🎉🇯🇵")
        await h.press(.left)
        await h.press(.right)
        h.textView.deleteBackward(nil); await h.tick()
        h.expectEqual(h.text, "ship it 👩‍💻🎉", "Backspace deletes a whole flag")
        h.textView.deleteBackward(nil); await h.tick()
        h.textView.deleteBackward(nil); await h.tick()
        h.expectEqual(h.text, "ship it ", "Backspace deletes a whole ZWJ sequence")
        await h.undo()
        h.expectEqual(h.text, "ship it 👩‍💻🎉🇯🇵", "undo restores the deleted emoji (deletes after a caret move are their own step)")
    }

    // MARK: Sending

    func sendKeys() async {
        var host = host()
        await h.type("line one")
        await h.press(.returnKey, .shift)
        await h.type("line two")
        await h.press(.returnKey, .option)
        await h.type("line three")
        h.expectEqual(h.text, "line one\nline two\nline three", "Shift-Return and Option-Return insert newlines")
        await h.press(.returnKey)
        h.expectEqual(h.text, "", "Return sends and clears at once (optimistic)")
        h.expectEqual(h.composer.controller.pendingSends, 1, "one send in flight; nothing claims delivery yet")
        h.expectEqual(host.submissions.count, 0, "not yet admitted")
        await h.pause(80)
        h.expectEqual(host.submissions.map(\.text), ["line one\nline two\nline three"], "admitted after the host answers")
        h.expectEqual(host.submissions.first?.delivery, .now, "idle send is .now")
        await h.press(.returnKey)
        await h.pause(40)
        h.expectEqual(host.submissions.count, 1, "Return on an empty draft sends nothing")

        h.reset(sendKey: .commandReturn)
        host = self.host()
        await h.type("first")
        await h.press(.returnKey)
        await h.type("second")
        h.expectEqual(h.text, "first\nsecond", "Command-Return mode: Return inserts a newline")
        await h.press(.returnKey, .command)
        await h.pause(60)
        h.expectEqual(host.submissions.map(\.text), ["first\nsecond"], "Command-Return sends")
    }

    func sendFailure() async {
        let host = host()
        host.failures = ["opencode is not connected. Nothing was sent."]
        await h.type("please fix the build")
        await h.press(.returnKey)
        h.expectEqual(h.text, "", "cleared while sending")
        await h.pause(80)
        h.expectEqual(h.text, "please fix the build", "draft restored on failure")
        h.expectEqual(h.composer.visibleError, "opencode is not connected. Nothing was sent.", "error shown inline")
        h.expectEqual(host.draft.text, "please fix the build", "restored draft persisted to the host")
        await h.snapshot("error")

        // Typing while a failing send is in flight: both texts survive.
        host.failures = ["Server error."]
        host.sendDelay = .milliseconds(120)
        await h.press(.returnKey)
        await h.type("and also run the tests")
        await h.pause(200)
        h.expectEqual(h.text, "please fix the build\n\nand also run the tests", "failed text merged before newer typing")
        host.sendDelay = .milliseconds(10)
        h.composer.controller.dismissError()
        h.expect(h.composer.visibleError == nil, "error dismissed")
    }

    func running() async {
        let host = host()
        host.runState = .running
        h.expectEqual(h.composer.primaryAction, .stop, "running + empty draft: Stop")
        await h.type("then update the docs")
        h.expectEqual(h.composer.primaryAction, .send(.queue), "running + draft: Queue by default")
        h.flags(.command)
        h.expectEqual(h.composer.primaryAction, .send(.steer), "holding Command flips to Steer")
        await h.snapshot("running-steer")
        h.flags([])
        h.expectEqual(h.composer.primaryAction, .send(.queue), "releasing Command flips back")
        await h.snapshot("running-queue")
        await h.press(.returnKey)
        await h.pause(60)
        h.expectEqual(host.submissions.last?.delivery, .queue, "Return queues while running")
        await h.type("focus on the parser first")
        await h.press(.returnKey, .command)
        await h.pause(60)
        h.expectEqual(host.submissions.last?.delivery, .steer, "Command-Return steers while running")
        host.supportsSteer = false
        await h.type("no steering here")
        await h.press(.returnKey, .command)
        await h.pause(60)
        h.expectEqual(host.submissions.last?.delivery, .queue, "steer falls back to queue when unsupported")
        await h.snapshot("running-stop")
        h.composer.stopAgent(nil)
        await h.pause(30)
        h.expectEqual(host.stopCalls, 1, "Stop calls the host")
        h.expectEqual(h.composer.primaryAction, .stopping, "Stopping until the server confirms")
        host.runState = .idle
        h.expectEqual(h.composer.primaryAction, .send(.now), "idle again")
        await h.press(.escape)
        h.expectEqual(host.stopCalls, 1, "Escape never stops")
    }

    // MARK: Completion and tokens

    func mentionUndo() async {
        let host = host()
        await h.type("Look at @mai")
        await h.composer.completion.settle()
        await h.pause(60)
        await h.composer.completion.settle()
        h.expect(h.composer.completion.isOpen, "@ opens the file completion")
        h.expectEqual(h.composer.completion.selectedItem?.id, "Sources/App/main.swift", "best match first")
        h.expect(!(h.composer.completion.items.contains { $0.id.hasPrefix("node_modules") }), "node_modules skipped")
        h.expect(h.composer.completionView != nil, "popover visible")
        await h.snapshot("completion")
        await h.press(.down)
        await h.press(.up)
        await h.press(.returnKey)
        h.expectEqual(h.text, "Look at @Sources/App/main.swift ", "Return accepts and adds a space")
        h.expect(!h.composer.completion.isOpen, "popover closed after accept")
        h.expectEqual(host.submissions.count, 0, "accepting does not send")
        let tokens = TokenText.placedTokens(in: h.textView.textStorage!)
        h.expectEqual(tokens.count, 1, "one token")
        let id = tokens.first?.token.id
        await h.snapshot("token")

        await h.undo()
        h.expectEqual(h.text, "Look at @mai", "undo removes the token in one step")
        await h.redo()
        h.expectEqual(h.text, "Look at @Sources/App/main.swift ", "redo")
        h.expectEqual(TokenText.placedTokens(in: h.textView.textStorage!).first?.token.id, id, "token identity survives undo/redo")

        h.textView.setSelectedRange(NSRange(location: 12, length: 0))
        h.expect(h.textView.selectedRange().location == 8 || h.textView.selectedRange().location == 31, "caret never rests inside a token")
        h.textView.setSelectedRange(NSRange(location: h.text.utf16.count, length: 0))
        h.textView.deleteBackward(nil); await h.tick()
        h.textView.deleteBackward(nil); await h.tick()
        h.expectEqual(h.text, "Look at ", "Backspace deletes the whole token")
        await h.undo()
        h.expect(h.text.hasPrefix("Look at @Sources/App/main.swift"), "undo restores the token")
        h.expectEqual(TokenText.placedTokens(in: h.textView.textStorage!).count, 1, "restored as a token")

        h.textView.setSelectedRange(NSRange(location: 0, length: h.textView.string.utf16.count))
        let pasteboard = h.newPasteboard()
        _ = h.textView.writeSelection(to: pasteboard, types: [.string])
        h.expect(pasteboard.string(forType: .string)?.contains("@Sources/App/main.swift") == true, "copy gives the text form")

        h.textView.setSelectedRange(NSRange(location: h.text.utf16.count, length: 0))
        await h.type("and @zzzqqq")
        await h.pause(80)
        await h.composer.completion.settle()
        h.expect(h.composer.completion.isOpen && h.composer.completion.items.isEmpty, "no matches is shown, not hidden")
        await h.press(.escape)
        h.expect(!h.composer.completion.isOpen, "Escape closes the popover")
        await h.type("q")
        await h.pause(60)
        h.expect(!h.composer.completion.isOpen, "a dismissed query stays dismissed while typing")
        h.expect(h.text.hasSuffix("@zzzqqqq"), "Escape changed no text")
        await h.press(.returnKey)
        await h.pause(60)
        h.expectEqual(host.submissions.first?.tokens.count, 1, "the submission carries the token")
        h.expectEqual(host.submissions.first?.tokens.first?.token.kind, .file, "file token")
    }

    func slashCommand() async {
        let host = host()
        await h.type("/rev")
        await h.pause(60)
        await h.composer.completion.settle()
        h.expectEqual(h.composer.completion.selectedItem?.title, "/review", "slash command ranked")
        await h.press(.tab)
        h.expectEqual(h.text, "/review ", "Tab accepts")
        await h.type("the diff, path a/b")
        await h.pause(60)
        h.expect(!h.composer.completion.isOpen, "/ inside a path does not trigger")
        await h.press(.returnKey)
        await h.pause(60)
        h.expectEqual(host.submissions.first?.tokens.first?.token.kind, .command, "command token sent")
    }

    // MARK: Paste

    func paste() async {
        let host = host()
        let pasteboard = h.newPasteboard()
        pasteboard.declareTypes([.png, .string], owner: nil)
        pasteboard.setData(Harness.samplePNG(), forType: .png)
        pasteboard.setString("Here is the failing screen", forType: .string)
        _ = h.textView.readSelection(from: pasteboard, type: .png); await h.tick()
        h.expectEqual(h.composer.attachments.count, 1, "pasted image becomes a chip")
        h.expectEqual(h.composer.attachments.items.first?.kind, .image, "image kind")
        h.expectEqual(h.text, "Here is the failing screen", "text from the same paste goes in as plain text")
        h.expect(h.textView.textStorage!.attribute(.link, at: 0, effectiveRange: nil) == nil, "plain text")

        let rich = h.newPasteboard()
        rich.declareTypes([.rtf, .string], owner: nil)
        rich.setData(try? NSAttributedString(string: " bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
            .data(from: NSRange(location: 0, length: 5), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
            forType: .rtf)
        rich.setString(" bold", forType: .string)
        _ = h.textView.readSelection(from: rich, type: .string); await h.tick()
        let font = h.textView.textStorage!.attribute(.font, at: h.text.utf16.count - 1, effectiveRange: nil) as? NSFont
        h.expectEqual(font?.pointSize, NSFont.systemFontSize, "rich paste arrives as plain text")

        let files = h.newPasteboard()
        let fileURL = h.projectRoot.appending(path: "README.md")
        files.writeObjects([fileURL as NSURL])
        _ = h.textView.readSelection(from: files, type: .fileURL); await h.tick()
        h.expectEqual(h.composer.attachments.count, 2, "pasted file becomes a chip")
        _ = h.textView.readSelection(from: files, type: .fileURL); await h.tick()
        h.expectEqual(h.composer.attachments.count, 2, "the same file is not attached twice")
        h.expect(h.composer.visibleError?.contains("already attached") == true, "duplicate is explained")

        await h.pause(20)
        let large = String(repeating: "log line with some detail\n", count: 1400)
        let big = h.newPasteboard()
        big.setString(large, forType: .string)
        _ = h.textView.readSelection(from: big, type: .string); await h.tick()
        h.expectEqual(h.composer.attachments.count, 3, "a large paste becomes a text attachment")
        h.expectEqual(h.composer.attachments.items.last?.kind, .text, "text kind")
        h.expect(!h.text.contains("log line"), "large paste kept out of the prompt")
        await h.snapshot("attachments")
        await h.pause(20)
        await h.undo()
        h.expectEqual(h.composer.attachments.count, 2, "undo removes the text attachment")
        await h.redo()
        h.expectEqual(h.composer.attachments.count, 3, "redo restores it")

        if let id = h.composer.attachments.items.first?.id { h.composer.removeAttachment(id: id) }
        h.expectEqual(h.composer.attachments.count, 2, "remove button removes")
        await h.undo()
        h.expectEqual(h.composer.attachments.items.first?.kind, .image, "undo puts it back in place")

        await h.press(.returnKey)
        await h.pause(60)
        h.expectEqual(host.submissions.first?.attachments.count, 3, "attachments go to the host on send")
        h.expectEqual(h.composer.attachments.count, 0, "chips cleared after send")
    }

    // MARK: History

    func history() async {
        let host = host(prompts: ["first prompt", "second prompt\nwith two lines"])
        h.composer.host = nil
        h.composer.host = host
        await h.type("draft in progress")
        await h.press(.up)
        h.expectEqual(h.text, "draft in progress", "first Up moves the caret to the start, keeps the draft")
        h.expectEqual(h.textView.selectedRange().location, 0, "caret at start")
        await h.press(.up)
        h.expectEqual(h.text, "second prompt\nwith two lines", "Up at the start recalls the newest prompt")
        await h.press(.up)
        h.expectEqual(h.text, "second prompt\nwith two lines", "Up inside a multi-line entry moves a line")
        await h.press(.up)
        h.expectEqual(h.text, "first prompt", "Up on the first line recalls the older prompt")
        await h.press(.up)
        h.expectEqual(h.text, "first prompt", "nothing older")
        await h.press(.down)
        h.expectEqual(h.text, "second prompt\nwith two lines", "Down recalls newer")
        await h.press(.down)
        h.expectEqual(h.text, "draft in progress", "Down past the newest restores the draft")
        await h.press(.up)
        await h.press(.up)
        h.expectEqual(h.text, "second prompt\nwith two lines", "recall again")
        await h.undo()
        h.expectEqual(h.text, "draft in progress", "Undo also restores the draft")
        h.composer.completion.close()
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        h.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        await h.press(.up)
        h.expect(h.text.hasPrefix("か"), "no recall while composing")
        h.textView.unmarkText()
        _ = host
    }

    // MARK: Growth

    func growth() async {
        _ = host()
        await h.composer.settle()
        let oneLine = h.composer.textAreaHeight
        await h.type("short")
        await h.composer.settle()
        h.expectEqual(h.composer.textAreaHeight, oneLine, "one line stays one line")
        await h.press(.returnKey, .shift)
        await h.composer.settle()
        h.expect(h.composer.textAreaHeight > oneLine, "a second line grows the field")
        let twoLines = h.composer.textAreaHeight
        await h.type("third line")
        let selection = h.textView.selectedRange()
        await h.composer.settle()
        h.expectEqual(h.textView.selectedRange(), selection, "growth keeps the selection")
        await h.type(String(repeating: "\nmore", count: 60))
        await h.composer.settle()
        h.expectEqual(h.composer.textAreaHeight, h.composer.textAreaMaximumHeight, "capped at the maximum")
        h.expect(h.composer.textAreaHeight < h.window.contentView!.bounds.height * 0.5, "cap is a fraction of the window")
        h.expect(h.textView.visibleRect.maxY >= h.textView.bounds.maxY - 2, "caret line stays visible when capped")
        await h.snapshot("capped")
        h.textView.selectAll(nil)
        h.textView.deleteBackward(nil); await h.tick()
        await h.composer.settle()
        h.expectEqual(h.composer.textAreaHeight, oneLine, "shrinks back to one line")
        await h.undo()
        await h.composer.settle()
        h.expectEqual(h.composer.textAreaHeight, h.composer.textAreaMaximumHeight, "undo grows it again")
        h.metrics["growth.heights"] = "one line \(oneLine) pt, two lines \(twoLines) pt, cap \(h.composer.textAreaMaximumHeight) pt"

        var hero = ComposerStyle()
        hero.minimumLines = 3
        h.reset(style: hero)
        _ = host()
        await h.composer.settle()
        h.expect(h.composer.textAreaHeight > twoLines, "hero style starts at three lines")
        await h.snapshot("hero")
    }

    // MARK: Threads

    func threadSwitch() async {
        let alpha = FakeHost(key: "alpha", draft: ComposerDraft(text: "alpha draft", selection: NSRange(location: 2, length: 3)))
        let beta = FakeHost(key: "beta", draft: ComposerDraft(text: "beta"))
        h.composer.host = alpha
        h.expectEqual(h.text, "alpha draft", "alpha's draft shown")
        h.expectEqual(h.textView.selectedRange(), NSRange(location: 2, length: 3), "alpha's selection restored")
        h.textView.setSelectedRange(NSRange(location: 11, length: 0))
        await h.type(" more")
        h.composer.host = beta
        h.expectEqual(alpha.draft.text, "alpha draft more", "alpha saved on switch (no debounce loss)")
        h.expectEqual(h.text, "beta", "beta shown, no leak")
        h.expect(h.textView.undoManager?.canUndo == false, "undo does not cross threads")
        h.composer.host = alpha
        h.expectEqual(h.text, "alpha draft more", "alpha back")
        h.expectEqual(h.textView.selectedRange(), NSRange(location: 16, length: 0), "alpha's caret back")

        alpha.failures = ["Server error."]
        alpha.sendDelay = .milliseconds(80)
        await h.press(.returnKey)
        h.composer.host = beta
        await h.pause(150)
        h.expectEqual(h.text, "beta", "a failed send in another thread does not touch this one")
        h.expectEqual(alpha.draft.text, "alpha draft more", "it is restored into its own thread")

        await h.type(" typed")
        await h.pause(120)
        h.expectEqual(beta.draft.text, "beta typed", "debounced save while typing")
        h.expect(beta.saves >= 1, "saved through the host")
    }

    // MARK: Misc

    func spellcheck() async {
        _ = host()
        await h.type("Please refactor the parser so it is easier to read")
        await h.pause(320)
        h.expect(h.composer.isSpellCheckingEnabled, "prose: spell checking on")
        await h.type("\n```swift\nfunc parse() -> [Token] { tokens.map { $0 } }\n```")
        await h.pause(320)
        h.expect(!h.composer.isSpellCheckingEnabled, "code: spell checking off")
        h.expect(!h.textView.isAutomaticQuoteSubstitutionEnabled && !h.textView.isAutomaticSpellingCorrectionEnabled,
                 "no smart quotes or autocorrect")
    }

    func escape() async {
        let host = host()
        await h.type("keep me")
        await h.press(.escape)
        await h.pause(30)
        h.expectEqual(h.text, "keep me", "Escape keeps the text")
        h.expectEqual(host.submissions.count + host.stopCalls, 0, "Escape neither sends nor stops")
    }

    func accessibility() async {
        let host = host()
        let pasteboard = h.newPasteboard()
        pasteboard.setData(Harness.samplePNG(), forType: .png)
        _ = h.textView.readSelection(from: pasteboard, type: .png); await h.tick()
        let views = h.allViews()
        let labels = views.compactMap { $0.accessibilityLabel() }
        h.expect(labels.contains("Message"), "text view labelled")
        h.expect(labels.contains { $0.hasPrefix("Image attachment, Pasted image.png") }, "chip labelled with kind, name, size")
        h.expect(labels.contains("Remove Pasted image.png"), "remove button labelled")
        h.expect(labels.contains("Send"), "send button labelled")
        host.runState = .running
        h.expect(h.allViews().compactMap { $0.accessibilityLabel() }.contains("Queue"), "queue labelled while running")
        h.textView.selectAll(nil)
        h.textView.deleteBackward(nil); await h.tick()
        if let id = h.composer.attachments.items.first?.id { h.composer.removeAttachment(id: id) }
        h.expect(h.allViews().compactMap { $0.accessibilityLabel() }.contains("Stop the agent"), "stop labelled")
        h.expect(h.allViews().contains { ($0 as? NSButton)?.accessibilityLabel() == "Follow-up options" }, "follow-up menu reachable")
    }

    func latency() async {
        _ = host()
        await h.composer.settle()
        var samples: [Duration] = []
        let clock = ContinuousClock()
        for index in 0..<400 {
            let character = index % 60 == 59 ? "\n" : String("the quick brown fox ".randomElement()!)
            let start = clock.now
            h.textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            h.composer.updateTextHeight()
            h.window.contentView?.layoutSubtreeIfNeeded()
            h.window.contentView?.displayIfNeeded()
            samples.append(start.duration(to: clock.now))
        }
        func ms(_ d: Duration) -> String { String(format: "%.2f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        let sorted = samples.sorted()
        h.metrics["typing.p50"] = ms(sorted[sorted.count / 2])
        h.metrics["typing.p95"] = ms(sorted[sorted.count * 95 / 100])
        h.metrics["typing.max"] = ms(sorted.last!)
        h.expect(sorted[sorted.count * 95 / 100] < .milliseconds(16), "p95 keystroke (insert + height + layout + display) under one frame")

        // A large inline draft (2,000 lines, ~90 KB): keystroke cost at the end, and the full height measurement.
        let big = (0..<2000).map { "line \($0): the quick brown fox jumps over the lazy dog" }.joined(separator: "\n")
        h.textView.insertText(big, replacementRange: NSRange(location: NSNotFound, length: 0))
        await h.composer.settle()
        var bigSamples: [Duration] = []
        for _ in 0..<100 {
            let start = clock.now
            h.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            h.composer.updateTextHeight()
            h.window.contentView?.layoutSubtreeIfNeeded()
            h.window.contentView?.displayIfNeeded()
            bigSamples.append(start.duration(to: clock.now))
        }
        let bigSorted = bigSamples.sorted()
        h.metrics["typing.2000-lines.p50"] = ms(bigSorted[bigSorted.count / 2])
        h.metrics["typing.2000-lines.p95"] = ms(bigSorted[bigSorted.count * 95 / 100])
        h.textView.selectAll(nil)
        h.textView.insertText("", replacementRange: h.textView.selectedRange())
        let start = clock.now
        h.textView.insertText(big, replacementRange: NSRange(location: NSNotFound, length: 0))
        h.composer.updateTextHeight()
        h.metrics["growth.insert-and-measure-2000-lines"] = ms(start.duration(to: clock.now))
    }

    func snapshots() async {
        _ = host()
        await h.snapshot("empty")
        await h.type("Refactor ")
        h.composer.insert(token: ComposerToken(kind: .file, text: "@Sources/ComposerKit/Tokens.swift", value: "/tmp/Tokens.swift"))
        await h.type("so tokens delete as a unit, and add tests.\nKeep the public API unchanged.")
        let pasteboard = h.newPasteboard()
        pasteboard.setData(Harness.samplePNG(), forType: .png)
        _ = h.textView.readSelection(from: pasteboard, type: .png); await h.tick()
        h.composer.add(attachments: [.file(at: h.projectRoot.appending(path: "Package.swift"))])
        await h.snapshot("draft")
        h.window.makeFirstResponder(nil)
        await h.snapshot("unfocused")
    }
}
