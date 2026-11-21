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
}
