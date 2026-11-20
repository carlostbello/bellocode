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
