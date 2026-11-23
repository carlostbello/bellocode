import Foundation
import Testing

@testable import ContainerKit

/// R14: the images a Dockerfile pulls are what the registry allowlist applies to.
@Suite("Dockerfile base images")
struct DockerfileBasesTests {
    func images(_ text: String, _ args: [String: String] = [:]) -> [String]? { try? DockerfileBases.images(in: text, buildArgs: args).get() }

    @Test func fromLinesStagesAndScratch() {
        #expect(images("FROM node:20\nRUN npm ci\n") == ["node:20"])
        #expect(images("""
            # syntax comment
            FROM --platform=linux/amd64 golang:1.23 AS build
            RUN go build
            FROM build AS test
            FROM scratch
            COPY --from=build /app /app
            COPY --from=0 /x /y
            COPY --from=ghcr.io/acme/tools:1 /bin/tool /bin/tool
            RUN --mount=type=bind,from=docker.io/library/busybox:1,target=/bb ls /bb
            """) == ["golang:1.23", "ghcr.io/acme/tools:1", "docker.io/library/busybox:1"])
    }

    @Test func argumentsAreExpandedFromGlobalArgsAndBuildArgs() {
        let file = "ARG REGISTRY=docker.io\nARG TAG\nFROM ${REGISTRY}/library/python:${TAG:-3.12}\n"
        #expect(images(file) == ["docker.io/library/python:3.12"])
        #expect(images(file, ["REGISTRY": "evil.example.com", "TAG": "3"]) == ["evil.example.com/library/python:3"])
        #expect(images("ARG BASE\nFROM $BASE\n", ["BASE": "alpine:3"]) == ["alpine:3"])
    }

    @Test func aReferenceThatCannotBeResolvedIsRefusedNotGuessed() {
        guard case .failure(let refusal) = DockerfileBases.images(in: "ARG BASE\nFROM $BASE\n") else {
            Issue.record("an unresolved base image was accepted")
            return
        }
        #expect(refusal.reason.contains("$BASE"))
        // An ARG after the first FROM is a stage argument: it does not feed later FROM lines.
        if case .success = DockerfileBases.images(in: "FROM alpine\nARG LATER=x\nFROM ${LATER}\n") { Issue.record("stage ARG used for FROM") }
    }

    @Test func continuationsCommentsHeredocsAndTheEscapeDirective() {
        // A well-formed FROM line in a heredoc body is checked too (a parser that disagrees about the heredoc would
        // build it); script lines that are not Docker's FROM grammar are not.
        #expect(images("FROM \\\n  alpine:3 \\\n  AS base\nRUN <<EOF\nFROM evil.example.com/x\nEOF\nFROM base\n") == ["alpine:3", "evil.example.com/x"])
        #expect(images("FROM alpine:3\nRUN <<EOF python3\nfrom os import path\nimport sys\nEOF\n") == ["alpine:3"])
        #expect(images("# escape=`\nFROM `\n  debian:12\n") == ["debian:12"])
        #expect(images("#FROM evil.example.com/x\nFROM alpine\n") == ["alpine"])
    }

    /// N04: a quoted `<<` opens no heredoc, so the FROM after it is checked (BuildKit's parser builds it).
    @Test func aQuotedHeredocMarkerHidesNothing() {
        #expect(images("FROM registry.acme.internal/base:1\nRUN echo \"<<EOF\"\nFROM evil.example.com/exfil:latest\n")?.contains("evil.example.com/exfil:latest") == true)
        #expect(images("FROM a:1\nRUN echo '<<EOF'\nCOPY --from=evil.example.com/t:1 /x /x\n")?.contains("evil.example.com/t:1") == true)
        #expect(images("FROM a:1\nENV X=<<EOF\nFROM evil.example.com/e:1\n")?.contains("evil.example.com/e:1") == true, "ENV opens no heredoc")
        // A real heredoc that is never closed is refused (BuildKit fails it; skipping to the end would hide lines).
        guard case .failure(let refusal) = DockerfileBases.images(in: "FROM a:1\nRUN <<EOF\nFROM evil.example.com/x\n") else {
            Issue.record("an unterminated heredoc was accepted")
            return
        }
        #expect(refusal.reason.contains("never closed"))
        // Two heredocs on one line, and ONBUILD.
        #expect(images("FROM a:1\nCOPY <<A <<B /x/\nFROM b:1 AS x\nA\nalso\nB\nFROM c:1\n") == ["a:1", "c:1", "b:1"])
        #expect(images("FROM a:1\nONBUILD RUN <<EOF\necho\nEOF\nFROM d:1\n") == ["a:1", "d:1"])
    }

    /// N04: a `# syntax=` frontend (and `BUILDKIT_SYNTAX`) is an image BuildKit pulls and runs.
    @Test func theSyntaxFrontendIsAnImage() {
        #expect(images("# syntax=evil.registry/frontend:latest\nFROM alpine:3\n") == ["evil.registry/frontend:latest", "alpine:3"])
        #expect(images("#SYNTAX = docker/dockerfile:1\n# escape=`\nFROM alpine:3\n") == ["docker/dockerfile:1", "alpine:3"])
        // Collected from any comment before the first instruction, more than BuildKit honours.
        #expect(images("# hello\n# syntax=evil.registry/f:1\nFROM alpine:3\n") == ["evil.registry/f:1", "alpine:3"])
        #expect(images("FROM alpine:3\n", ["BUILDKIT_SYNTAX": "evil.registry/g:2"]) == ["evil.registry/g:2", "alpine:3"])
        guard case .failure = DockerfileBases.images(in: "# syntax=${X}\nFROM alpine\n") else { Issue.record("a variable frontend was accepted"); return }
    }

    /// N04: the escape directive counts only where BuildKit honours it (consecutive directives at the very top), so a
    /// later `# escape=` cannot make the checker join lines Docker keeps apart.
    @Test func theEscapeDirectiveCountsOnlyAtTheTop() {
        let late = "# a comment\n# escape=`\nFROM registry.acme.internal/base:1 `\nFROM evil.example.com/x:1\n"
        #expect(images(late)?.contains("evil.example.com/x:1") == true)
        let unknownFirst = "# foo=bar\n# escape=`\nFROM a:1 `\nFROM evil.example.com/y:1\n"
        #expect(images(unknownFirst)?.contains("evil.example.com/y:1") == true)
        // Empty lines inside a continuation are skipped (BuildKit joins across them).
        #expect(images("FROM \\\n\n  alpine:3\n") == ["alpine:3"])
        guard case .failure = DockerfileBases.images(in: "# escape=`\n# escape=\\\\\nFROM a\n") else { Issue.record("two escape directives accepted"); return }
    }

    /// AF11: a Windows-edited (CRLF) Dockerfile with a leading comment is read line by line like Docker reads it, so its
    /// base image is checked; so is one where a combining mark follows `#` or the escape character.
    @Test func crlfAndCombiningMarksDoNotHideInstructions() {
        #expect(images("# built on Windows\r\nFROM evil.example.com/x:1\r\nRUN true\r\n") == ["evil.example.com/x:1"])
        #expect(images("# syntax=docker/dockerfile:1\r\nFROM alpine:3 \\\r\n  AS base\r\nFROM base\r\n") == ["docker/dockerfile:1", "alpine:3"])
        #expect(images("FROM a:1\r\nRUN <<EOF\r\nFROM b:2\r\nEOF\r\nFROM c:3\r\n") == ["a:1", "c:3", "b:2"])
        // `#` plus a combining mark is a comment to Docker (its line starts with `#`); its trailing escape joins nothing.
        #expect(images("#\u{301} comment \\\nFROM evil.example.com/y:1\n") == ["evil.example.com/y:1"])
        // A lone CR is not a line break to Docker.
        #expect(DockerfileBases.physicalLines("a\rb\r\nc\n") == ["a\rb", "c", ""])
    }

    /// AF12: a global ARG without a name is refused (Docker fails the file), never a crash.
    @Test func aGlobalArgWithoutANameIsRefused() {
        for file in ["ARG =\nFROM alpine\n", "ARG =x\nFROM alpine\n", "ARG A=1 =\nFROM alpine\n"] {
            guard case .failure(let refusal) = DockerfileBases.images(in: file) else {
                Issue.record("accepted \(file.debugDescription)")
                continue
            }
            #expect(refusal.reason.contains("has no name"))
        }
        #expect(images("ARG A=\nFROM alpine${A}\n") == ["alpine"], "an empty value is still a value")
    }

    func refused(_ text: String, _ args: [String: String] = [:]) -> String? {
        if case .failure(let refusal) = DockerfileBases.images(in: text, buildArgs: args) { return refusal.reason }
        return nil
    }

    /// GV01: Go's `unicode.IsSpace` is the White_Space property; Swift's `isWhitespace` is the same set.
    @Test func goBlanksAreTheWhiteSpaceProperty() {
        let go: [UInt32] = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680] + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
        for value in 0...0x3100 {
            let scalar = Unicode.Scalar(UInt32(value))!
            #expect(DockerfileBases.isGoSpace(scalar) == go.contains(UInt32(value)), "U+\(String(value, radix: 16))")
        }
    }

    /// GV01: Docker strips a form feed, vertical tab, NEL, no-break space (any Go blank) before an instruction or a
    /// directive; such a file is refused, never read with the instruction missing.
    @Test func blanksDockerReadsDifferentlyRefuseTheFile() {
        for blank in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{00A0}", "\u{2028}", "\u{3000}", "\u{001F}"] {
            let reason = refused("FROM registry.acme.internal/base:1\n\(blank)FROM evil.example.com/x:1\n")
            #expect(reason?.contains("cannot read the file the way Docker does") == true, "\(blank.unicodeScalars.first!.value): \(reason ?? "accepted")")
            // A hidden escape directive: Docker would use the backtick and join other lines than BelloCode.
            #expect(refused("\(blank)# escape=`\nFROM a:1\nRUN true #`\nFROM evil.example.com/y:1\n") != nil, "escape after U+\(blank.unicodeScalars.first!.value)")
            // Between words, after the escape, in a continuation line, on an empty line.
            #expect(refused("FROM\(blank)evil.example.com/z:1\n") != nil)
            #expect(refused("FROM a:1 \\\(blank)\nFROM evil.example.com/z:1\n") != nil)
            #expect(refused("FROM \\\n\(blank)evil.example.com/z:1\n") != nil)
            #expect(refused("FROM a:1\n\(blank)\nRUN true\n") != nil)
        }
        // Where Docker never reads them: a comment after the first instruction, a heredoc body.
        #expect(images("FROM a:1\n#\u{00A0}note\u{000C}\nRUN <<EOF\necho\u{00A0}\u{000C}\nEOF\n") == ["a:1"])
    }

    /// AF11: a byte-order mark is dropped from the first line for the instructions too, so the first FROM is checked.
    @Test func aByteOrderMarkHidesNothing() throws {
        #expect(images("\u{FEFF}FROM evil.example.com/bom:1\n") == ["evil.example.com/bom:1"])
        #expect(images("\u{FEFF}# escape=`\nFROM `\n  debian:12\n") == ["debian:12"])
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("FROM evil.example.com/bom:2\r\n".utf8)
        #expect(try DockerfileBases.images(in: bytes).get() == ["evil.example.com/bom:2"])
        // Bytes Docker would read differently from a lossy decoding are refused.
        #expect(throws: DockerfileBases.Refusal.self) { try DockerfileBases.images(in: Data("FROM a:1\n".utf8) + Data([0xC3, 0x28])).get() }
    }

    /// Docker joins a continued line with nothing in between, drops every trailing CR, and reads builder flags byte by
    /// byte (0xA0 inside `à` ends a flag word).
    @Test func linesAndFlagsAsDockerJoinsAndSplitsThem() {
        #expect(images("FRO\\\nM evil.example.com/join:1\n") == ["evil.example.com/join:1"])
        #expect(images("FROM a:1\r\r\n") == ["a:1"])
        #expect(images("FROM --platform=x\u{00E0}evil.example.com/flag:1\n") == ["evil.example.com/flag:1"])
        #expect(images("FROM a:1\nRUN --mount=type=bind,\"from=evil.example.com/m:1\",target=/x true\n") == ["a:1", "evil.example.com/m:1"])
        #expect(images("FROM a:1\nRUN --mount=type=bind,'\"from=evil.example.com/m:2\"' true\n") == ["a:1", "evil.example.com/m:2"])
        #expect(refused("FROM a:1\nRUN --mount=type=bind,fr\"om=x true\n") != nil, "a mount Docker's CSV reader fails")
    }

    /// AF11, GW01: BuildKit continues a line only when its trailing escape (blanks after it allowed) is the line's
    /// first character or follows something other than the escape (`([^X])X[ \t]*$|^X[ \t]*$`). Two or more escapes
    /// end the instruction, so the next line is a stage of its own whose base is checked.
    @Test func anEscapedEscapeEndsTheInstruction() {
        for (escape, directive) in [("\\", ""), ("`", "# escape=`\n")] {
            let two = escape + escape
            #expect(images(directive + "FROM allowed/base:1\nRUN echo x \(two)\nFROM disallowed.example.com/image:1\n")
                == ["allowed/base:1", "disallowed.example.com/image:1"], "two \(escape)")
            #expect(images(directive + "FROM allowed/base:1\nRUN echo x \(two)\(escape) \t\nFROM disallowed.example.com/image:2\n")
                == ["allowed/base:1", "disallowed.example.com/image:2"], "three \(escape)")
            #expect(images(directive + "FROM allowed/base:1\nRUN echo x\(two)  \nFROM disallowed.example.com/image:3\n")
                == ["allowed/base:1", "disallowed.example.com/image:3"], "two \(escape) then blanks")
            // One escape, an escape after a blank, and a line that is only the escape still continue.
            #expect(images(directive + "FROM allowed/base:1\nRUN echo x \(escape)\nFROM not-a-stage:1\n") == ["allowed/base:1"])
            #expect(images(directive + "FROM allowed/base:1\nRUN echo \(escape) \(escape)\nFROM not-a-stage:1\n") == ["allowed/base:1"])
            #expect(images(directive + "FROM \(escape)\n\(escape)\nallowed/base:2\n") == ["allowed/base:2"])
            // A continued line that ends in an escaped escape ends the instruction there.
            #expect(images(directive + "FROM allowed/base:1\nRUN echo \(escape)\nx \(two)\nFROM disallowed.example.com/image:4\n")
                == ["allowed/base:1", "disallowed.example.com/image:4"])
        }
        #expect(DockerfileBases.trimContinuation("a\\\\", escape: "\\") == ("a\\\\", true))
        #expect(DockerfileBases.trimContinuation("a\\ \t", escape: "\\") == ("a", false))
        #expect(DockerfileBases.trimContinuation("\\", escape: "\\") == ("", false))
        #expect(DockerfileBases.trimContinuation("\\\\", escape: "\\") == ("\\\\", true))
    }

    /// Global ARG defaults are expanded as Docker expands them; references Docker's shell processing would change
    /// (quotes) or that use a variable where BelloCode cannot know its value are refused.
    @Test func referencesAreCheckedAsDockerResolvesThem() {
        #expect(images("ARG A=evil.example.com/a:1\nARG B=$A\nFROM $B\n") == ["evil.example.com/a:1"])
        #expect(refused("ARG B=$UNSET\nFROM $B\n") != nil)
        #expect(refused("FROM \"evil.example.com/q:1\"\n") != nil)
        #expect(refused("ARG IMG=a:1\nFROM a:1\nARG IMG=evil.example.com/s:1\nCOPY --from=$IMG / /\n") != nil)
        #expect(refused("FROM a:1\nRUN --mount=from=${IMG},target=/x true\n") != nil)
    }

    /// Other frontends' directive forms (`//syntax=`, a JSON document) are refused; a heredoc ends only on its exact
    /// word; a `[` test in shell form still opens one.
    @Test func otherDirectiveFormsAndHeredocEnds() {
        #expect(refused("//syntax=evil.example.com/f:1\nFROM alpine\n") != nil)
        #expect(refused("#!/usr/bin/env docker\n// syntax = evil.example.com/f:1\nFROM alpine\n") != nil)
        #expect(refused("{\"syntax\": \"evil.example.com/f:1\"}\n") != nil)
        #expect(images("FROM a:1\nRUN <<EOF\n  EOF\nFROM b:1\nEOF\nFROM c:1\n") == ["a:1", "c:1", "b:1"])
        #expect(images("FROM a:1\nRUN <<-EOF\n\t\tEOF\nFROM c:1\n") == ["a:1", "c:1"])
        #expect(images("FROM a:1\nRUN [ -f /x ] && cat <<EOF\n\u{000C}body\nEOF\n") == ["a:1"])
    }
}
