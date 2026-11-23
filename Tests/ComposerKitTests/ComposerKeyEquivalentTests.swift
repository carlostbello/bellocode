import AppKit
import Testing

@testable import ComposerKit

/// v1.0.1 NV03: the composer claims only the Return combinations that send; menu shortcuts built on Command-Return
/// (⌃⌘↩ Run Suggested Git Action, ⌃⌥⌘↩ Submit Review…) reach the menu instead of inserting a newline.
@MainActor
@Suite(.serialized) struct ComposerKeyEquivalentTests {
    func composer(_ sendKey: SendKey) -> (ComposerViewController, NSWindow) {
        var configuration = ComposerConfiguration()
        configuration.sendKey = sendKey
        let composer = ComposerViewController(configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = composer
        window.makeFirstResponder(composer.textView)
        return (composer, window)
    }

    func returnKey(_ modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    @Test(arguments: SendKey.allCases)
    func menuShortcutsOnCommandReturnAreNotClaimed(_ sendKey: SendKey) throws {
        let (composer, window) = composer(sendKey)
        try #require(window.firstResponder === composer.textView)
        composer.textView.string = "draft"
        for modifiers: NSEvent.ModifierFlags in [[.control, .command], [.control, .option, .command], [.shift, .command]] {
            #expect(!composer.textView.performKeyEquivalent(with: returnKey(modifiers, in: window)), "\(modifiers)")
            #expect(composer.textView.string == "draft", "no newline inserted for \(modifiers)")
        }
        window.close()
    }

    @Test func theSendCombinationsAreStillClaimed() throws {
        let (composer, window) = composer(.commandReturn)
        try #require(window.firstResponder === composer.textView)
        #expect(composer.textView.performKeyEquivalent(with: returnKey(.command, in: window)), "⌘↩ sends")
        #expect(composer.textView.performKeyEquivalent(with: returnKey([.command, .option], in: window)), "⌥⌘↩ sends the alternate")
        let (other, otherWindow) = self.composer(.returnKey)
        #expect(other.textView.performKeyEquivalent(with: returnKey(.command, in: otherWindow)), "⌘↩ is the alternate send")
        window.close()
        otherWindow.close()
    }
}
