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
        #expect(images("FROM \\\n  alpine:3 \\\n  AS base\nRUN <<EOF\nFROM evil.example.com/x\nEOF\nFROM base\n") == ["alpine:3"])
        #expect(images("# escape=`\nFROM `\n  debian:12\n") == ["debian:12"])
        #expect(images("#FROM evil.example.com/x\nFROM alpine\n") == ["alpine"])
    }
}
