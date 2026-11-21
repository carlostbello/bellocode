import Foundation
import Testing

@testable import OpenCodeKit

/// Settings ▸ Models edits opencode.json in place: one value changes, every other byte stays.
@Suite("JSONC editor")
struct JSONCEditorTests {
    func parses(_ text: String) -> Bool { JSONCheck.syntaxError(in: Data(text.utf8)) == nil }

    @Test func setsATopLevelValueInTheTemplate() throws {
        let template = GlobalConfigFolder.template(for: .config)
        let edited = try JSONCEditor.setString("anthropic/claude-sonnet-5", at: ["model"], in: template)
        #expect(edited == "{\n  \"$schema\": \"https://opencode.ai/config.json\",\n  \"model\": \"anthropic/claude-sonnet-5\"\n}\n")
        #expect(JSONCEditor.string(at: ["model"], in: edited) == "anthropic/claude-sonnet-5")
    }

    @Test func replacesInPlaceAndKeepsCommentsAndTrailingCommas() throws {
        let text = """
            {
              // The owner's notes stay.
              "model": "opencode/big-pickle", /* inline */
              "agents": {
                "reviewer": { "model": "a/b" },
              },
            }
            """
        let edited = try JSONCEditor.setString("anthropic/claude-haiku-5#high", at: ["model"], in: text)
        #expect(edited == text.replacingOccurrences(of: "opencode/big-pickle", with: "anthropic/claude-haiku-5#high"))
        let nested = try JSONCEditor.setString("anthropic/claude-haiku-5", at: ["agents", "title", "model"], in: edited)
        #expect(parses(nested))
        #expect(nested.contains("// The owner's notes stay.") && nested.contains("/* inline */"))
        #expect(JSONCEditor.string(at: ["agents", "title", "model"], in: nested) == "anthropic/claude-haiku-5")
        #expect(JSONCEditor.string(at: ["agents", "reviewer", "model"], in: nested) == "a/b")
    }

    @Test func createsMissingObjectsWithMatchingIndentation() throws {
        let text = "{\n    \"$schema\": \"x\"\n}\n"
        let edited = try JSONCEditor.setString("p/m", at: ["agents", "title", "model"], in: text)
        #expect(edited == "{\n    \"$schema\": \"x\",\n    \"agents\": {\n      \"title\": {\n        \"model\": \"p/m\"\n      }\n    }\n}\n")
        let empty = try JSONCEditor.setString("p/m", at: ["model"], in: "{}")
        #expect(empty == "{\n  \"model\": \"p/m\"\n}")
    }

    @Test func removingTakesTheMemberAndEmptyParentsAway() throws {
        let text = "{\n  \"$schema\": \"x\",\n  \"model\": \"p/m\",\n  \"agents\": {\n    \"title\": {\n      \"model\": \"p/s\"\n    }\n  }\n}\n"
        let noTitle = try JSONCEditor.setString(nil, at: ["agents", "title", "model"], in: text)
        #expect(noTitle == "{\n  \"$schema\": \"x\",\n  \"model\": \"p/m\"\n}\n")
        let noModel = try JSONCEditor.setString(nil, at: ["model"], in: noTitle)
        #expect(noModel == "{\n  \"$schema\": \"x\"\n}\n")
        // A member in the middle takes its own line and comma.
        let middle = try JSONCEditor.setString(nil, at: ["model"], in: text)
        #expect(parses(middle) && !middle.contains("p/m") && middle.contains("p/s"))
        // The other agents stay when one is removed.
        let shared = "{ \"agents\": { \"title\": { \"model\": \"p/s\" }, \"reviewer\": { \"model\": \"a/b\" } } }"
        let kept = try JSONCEditor.setString(nil, at: ["agents", "title", "model"], in: shared)
        #expect(parses(kept) && JSONCEditor.string(at: ["agents", "reviewer", "model"], in: kept) == "a/b")
        #expect(JSONCEditor.value(at: ["agents", "title"], in: kept) == nil)
        // Removing what is not there changes nothing.
        #expect(try JSONCEditor.setString(nil, at: ["model"], in: "{ \"a\": 1 }") == "{ \"a\": 1 }")
    }

    @Test func refusesBrokenFilesAndNonObjects() throws {
        #expect(throws: JSONCEditor.EditError.self) { try JSONCEditor.setString("p/m", at: ["model"], in: "{ \"model\": ") }
        #expect(throws: JSONCEditor.EditError.notAnObject("agents")) {
            try JSONCEditor.setString("p/m", at: ["agents", "title", "model"], in: "{ \"agents\": [] }")
        }
    }

    @Test func handlesEscapesAndUnicodeKeys() throws {
        let text = "{ \"name\": \"say \\\"hi\\\" // not a comment\", \"émoji\": \"🙂\" }"
        let edited = try JSONCEditor.setString("p/m", at: ["model"], in: text)
        #expect(parses(edited))
        #expect(JSONCEditor.string(at: ["name"], in: edited) == "say \"hi\" // not a comment")
        #expect(JSONCEditor.string(at: ["émoji"], in: edited) == "🙂")
        #expect(JSONCEditor.string(at: ["model"], in: edited) == "p/m")
    }
}

/// Review regressions (docs/reviews/v1.0.0-*.md): line endings, comment placement and byte-for-byte preservation.
@Suite("JSONC review regressions")
struct JSONCReviewTests {
    func parses(_ text: String) -> Bool { JSONCheck.syntaxError(in: Data(text.utf8)) == nil }

    /// A25: the same valid document parses with LF, CRLF and CR line endings, and positions count lines alike.
    @Test func allLineEndingsParse() throws {
        let lines = ["{", "  // the owner's note", "  \"model\": \"a/b\", /* inline */", "  \"agents\": {},", "}"]
        for ending in ["\n", "\r\n", "\r"] {
            let text = lines.joined(separator: ending)
            #expect(parses(text), "ending \(ending.debugDescription)")
            #expect(JSONCEditor.string(at: ["model"], in: text) == "a/b")
            let edited = try JSONCEditor.setString("c/d", at: ["model"], in: text)
            #expect(edited == text.replacingOccurrences(of: "a/b", with: "c/d"))
            let broken = lines.joined(separator: ending) + ending + "x"
            #expect(JSONCheck.syntaxError(in: Data(broken.utf8))?.contains("line 6") == true, "\(JSONCheck.syntaxError(in: Data(broken.utf8)) ?? "")")
        }
    }

    /// N14: a comment after a trailing comma, a byte order mark, and an unterminated block comment.
    @Test func trailingCommaBeforeACommentBOMAndUnterminatedComment() throws {
        #expect(parses("{\"model\": \"a/b\", // comment\n}"))
        #expect(parses("{\"list\": [1, 2, /* two */ ]}"))
        #expect(parses("\u{FEFF}{\"model\": \"a/b\"}"))
        #expect(JSONCheck.syntaxError(in: Data("{\"model\": \"a/b\" /* never closed".utf8))?.contains("unterminated") == true)
        #expect(try JSONCEditor.setString("c/d", at: ["model"], in: "{\"model\": \"a/b\", // comment\n}") == "{\"model\": \"c/d\", // comment\n}")
    }

    /// A26/N15: removing the last member keeps the previous member's comment and standalone comments, byte for byte.
    @Test func removingTheLastMemberKeepsNeighbouringComments() throws {
        let text = "{\n  \"$schema\": \"x\", // keep: about the schema\n  // keep: standalone\n  \"model\": \"p/m\"\n}\n"
        let removed = try JSONCEditor.setString(nil, at: ["model"], in: text)
        #expect(removed == "{\n  \"$schema\": \"x\" // keep: about the schema\n  // keep: standalone\n}\n")
        #expect(parses(removed))
        // CRLF: the member's whole line goes, line break included.
        let crlf = "{\r\n  \"a\": 1,\r\n  \"model\": \"p/m\"\r\n}\r\n"
        #expect(try JSONCEditor.setString(nil, at: ["model"], in: crlf) == "{\r\n  \"a\": 1\r\n}\r\n")
    }

    /// N15: inserting after a member with a line comment leaves the comment on its own member's line.
    @Test func insertingKeepsTheLastMembersComment() throws {
        let text = "{\n  \"$schema\": \"x\" // about the schema\n}\n"
        let inserted = try JSONCEditor.setString("p/m", at: ["model"], in: text)
        #expect(inserted == "{\n  \"$schema\": \"x\", // about the schema\n  \"model\": \"p/m\"\n}\n")
        let trailing = "{\n  \"$schema\": \"x\", // about the schema\n}\n"
        let afterTrailing = try JSONCEditor.setString("p/m", at: ["model"], in: trailing)
        #expect(afterTrailing == "{\n  \"$schema\": \"x\", // about the schema\n  \"model\": \"p/m\"\n}\n")
        let crlf = "{\r\n  \"a\": 1\r\n}\r\n"
        #expect(try JSONCEditor.setString("p/m", at: ["model"], in: crlf) == "{\r\n  \"a\": 1,\r\n  \"model\": \"p/m\"\r\n}\r\n")
        #expect(parses(inserted) && parses(afterTrailing))
    }

    /// N14: a template is never written over a file that appeared meanwhile.
    @Test func ensureNeverReplacesAnExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bc-ensure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = GlobalConfigFolder(url: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"mine\": true}".utf8).write(to: folder.path(of: .config))
        let result = try folder.ensure(.config)
        #expect(!result.created)
        #expect(try String(contentsOf: folder.path(of: .config), encoding: .utf8) == "{\"mine\": true}")
        let fresh = try folder.ensure(.instructions)
        #expect(fresh.created)
    }
}
