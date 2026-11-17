import AppKit
import Foundation
import OpenCodeKit
import Testing

@testable import BrowserKit

@Suite("Browser logic")
struct BrowserLogicTests {
    @Test func addressesResolveToURLsOrSearches() {
        #expect(BrowserAddress.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserAddress.resolve("127.0.0.1:8080/app")?.absoluteString == "http://127.0.0.1:8080/app")
        #expect(BrowserAddress.resolve("example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(BrowserAddress.resolve("https://swift.org")?.absoluteString == "https://swift.org")
        #expect(BrowserAddress.resolve("swift concurrency")?.absoluteString.hasPrefix("https://duckduckgo.com/?q=swift%20concurrency") == true)
        #expect(BrowserAddress.resolve("   ") == nil)
        #expect(BrowserAddress.display(URL(string: "http://localhost:3000/")) == "http://localhost:3000")
    }

    @Test func devServerURLsAreFoundInOutput() {
        let output = "  VITE v5  ready\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: http://0.0.0.0:5173/, see https://vitejs.dev."
        #expect(BrowserAddress.devServerURLs(in: output).map(\.absoluteString) == ["http://localhost:5173/"])
        #expect(BrowserAddress.devServerURLs(in: "visit https://example.com:443").isEmpty)
    }

    @Test func historyCompletesAndRanks() {
        var history = BrowserHistory()
        let now = Date()
        history.record(URL(string: "http://localhost:3000/settings")!, title: "Settings", now: now)
        history.record(URL(string: "https://swift.org/documentation")!, title: "Docs", now: now)
        history.record(URL(string: "https://swift.org/documentation")!, title: "Docs", now: now)
        #expect(history.suggestions(for: "swift").first?.url == "https://swift.org/documentation")
        #expect(history.inlineCompletion(for: "swift.o") == "rg/documentation")
        #expect(history.inlineCompletion(for: "localhost:3") == "000/settings")
        #expect(history.suggestions(for: "Settings").count == 1)
        history.record(URL(string: "file:///etc/hosts")!, title: "x", now: now)
        #expect(history.entries.count == 2, "only web pages are recorded")
    }

    @Test func guidanceNamesEveryUnsupportedOperation() {
        for (operation, support, _) in OperationSupport.matrix where support == .unsupported {
            #expect(OperationSupport.guidance.contains(operation))
            #expect(OperationSupport.unsupportedFailure(operation).code == .unsupported)
        }
        #expect(OperationSupport.guidance.contains("WebKit"))
        #expect(OperationSupport.support(for: "click") == .supported)
        #expect(OperationSupport.support(for: "lighthouse") == .unsupported)
        #expect(OperationSupport.support(for: "something.new") == .unsupported)
    }

    @Test func projectProfilesAreStableAndDistinct() {
        let a = BrowserProfiles.identifier(forProject: "/Users/x/project")
        #expect(a == BrowserProfiles.identifier(forProject: "/Users/x/project"))
        #expect(a != BrowserProfiles.identifier(forProject: "/Users/x/other"))
    }

    @Test func downloadsGetUniqueNames() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "browser-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "report.csv"))
        #expect(BrowserDownloads.uniqueDestination(in: folder, suggested: "report.csv").lastPathComponent == "report 2.csv")
        #expect(BrowserDownloads.uniqueDestination(in: folder, suggested: "a/b:c").lastPathComponent == "a-b-c")
    }

    @Test func picksBecomeComposerContext() {
        let pick = BrowserPick(
            url: "http://localhost:3000/", pageTitle: "Home", selector: "#submit", tag: "button", role: "button", name: "Save",
            text: "Save", rect: CGRect(x: 10, y: 20, width: 80, height: 30), image: nil, note: "Make it larger")
        #expect(pick.contextText.contains("Selector: #submit") && pick.contextText.contains("Note: Make it larger"))
    }

    @MainActor @Test func keyChordsParseLikeTheReferenceDesktop() throws {
        let enter = try NativeInput.parse("Enter")
        #expect(enter.keyCode == 36 && enter.characters == "\r")
        let selectAll = try NativeInput.parse("Meta+A")
        #expect(selectAll.flags == .command && selectAll.charactersIgnoringModifiers == "a")
        #expect(NativeInput.editingAction(selectAll) == #selector(NSText.selectAll(_:)))
        #expect(try NativeInput.parse("B").flags == .shift)
        #expect(try NativeInput.parse("F5").keyCode == 96)
        #expect(throws: BrowserFailure.self) { try NativeInput.parse("Hyper+X") }
    }
}
