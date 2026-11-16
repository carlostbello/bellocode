// G5 spike scenarios. Each returns a process exit code and writes build/spikes/G5/<name>.json.

import AppKit
import Darwin
import Foundation
import SwiftTerm
import TerminalKit

@MainActor
struct Scenarios {
    let h: Harness
    let options: [String]

    init(_ harness: Harness, options: [String]) {
        h = harness
        self.options = options
    }

    func option(_ name: String) -> String? {
        guard let index = options.firstIndex(of: "--\(name)"), index + 1 < options.count else { return nil }
        return options[index + 1]
    }

    func run(_ name: String) async -> Int32 {
        switch name {
        case "contract": return await contract()
        case "diag": return await diag()
        case "perf": return await perf()
        case "compat": return await compat()
        case "latency": return await latency()
        case "memory": return await memory()
        case "idle": return await idle()
        default:
            h.say("unknown scenario \(name)")
            return 2
        }
    }

    // MARK: - Contract (model b)

    func contract() async -> Int32 {
        var report: Report = [:]
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
            h.say("\(condition ? "ok  " : "FAIL") \(label)")
        }
        do {
            let server = try await h.ensureServer()
            let client = server.client
            guard let sid = h.sessionID else { return 1 }

            // create / list / get
            let created = try await client.createTerminal(
                sessionID: sid, cwd: h.scratch.path, size: SpikeTerminalSize(cols: 100, rows: 30), title: "contract",
                env: h.remoteEnvironment(), command: SpikeShell.loginShell(), args: ["-l"]
            )
            check(created.id.hasPrefix("pty"), "create returns Pty.ID \(created.id)")
            check(created.status == "running" && created.pid > 0, "created terminal is running with a pid")
            let listed = try await client.listTerminals(sessionID: sid)
            check(listed.map(\.id) == [created.id], "list returns the terminal")
            report["created"] = ["status": created.status, "size": "\(created.size.cols)x\(created.size.rows)",
                                 "command": created.command, "cwd": created.cwd, "output": [created.output.head, created.output.tail]]
            report["daemonPID"] = server.daemonPID().map(Int.init) ?? -1

            // connect, write, stream
            let t1 = try await h.makeRemote(ptyID: created.id)
            check(await h.ready(t1), "shell answers through the WebSocket")
            check(await h.run(t1, "echo hello-g5") != nil, "write + output round trip")
            let rows = h.screenText(t1.view).joined(separator: "\n")
            check(rows.contains("hello-g5"), "output rendered in SwiftTerm buffer")
            let earlyRead = try await client.read(sessionID: sid, lines: nil)
            report["agentReadLines20"] = (try await client.read(sessionID: sid, lines: 20))?.screen.text ?? "nil"
            check(earlyRead?.screen.text.contains("hello-g5") == true, "agent read (terminal/read) sees the screen before any resize")
            report["agentReadBeforeResize"] = earlyRead?.screen.text ?? "nil"

            // resize via view (WebSocket resize frame) and via PUT
            t1.view.setFrameSize(NSSize(width: 700, height: 400))
            await h.pause(400)
            let viewDims = t1.view.terminalDimensions
            let afterViewResize = try await client.terminal(created.id)
            check(afterViewResize.size.cols == viewDims.cols && afterViewResize.size.rows == viewDims.rows,
                  "WebSocket resize frame reaches the server (\(afterViewResize.size.cols)x\(afterViewResize.size.rows) vs view \(viewDims.cols)x\(viewDims.rows))")
            await h.run(t1, "stty size > \(h.scratch.path)/stty.txt")
            let stty = (try? String(contentsOfFile: "\(h.scratch.path)/stty.txt", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            check(stty == "\(viewDims.rows) \(viewDims.cols)", "shell sees the new size (stty \(stty))")
            let put = try await client.resize(created.id, to: SpikeTerminalSize(cols: 90, rows: 25), attachmentID: t1.connection?.attachmentID)
            check(put.size.cols == 90 && put.size.rows == 25, "PUT size updates the PTY")
            await h.pause(300)
            // restore the view's size (the view is the source of truth while attached)
            t1.view.setFrameSize(h.terminalFrame.size)
            await h.pause(300)

            // snapshot + agent read
            let snapshot = try await client.snapshot(created.id)
            check(snapshot.text.contains("hello-g5"), "snapshot text contains output")
            report["snapshot"] = ["textChars": snapshot.text.count, "checkpointBytes": snapshot.checkpoint.count,
                                  "cursor": [snapshot.cursor.x, snapshot.cursor.y]]
            let read = try await client.read(sessionID: sid, lines: 20)
            report["agentReadAfterResizeText"] = read?.screen.text ?? "nil"
            report["agentRead"] = ["ptyID": read?.ptyID ?? "", "cols": read?.screen.cols ?? 0, "rows": read?.screen.rows ?? 0,
                                   "foregroundProcess": read?.foregroundProcess ?? "nil", "textChars": read?.screen.text.count ?? 0]

            // close the view while output continues, reattach from cursor 0 (full retained replay)
            t1.type("sleep 1; echo while-detached-g5\r")
            let offsetBefore = t1.connection?.offset ?? 0
            let raw1 = t1.connection?.rawControl.value ?? []
            t1.close()
            await h.pause(2500)
            let t2 = try await h.makeRemote(ptyID: created.id, cursor: 0)
            check(await h.waitUntil(timeout: .seconds(5)) { t2.replayDone.value }, "reattach: replay_complete received")
            await h.pause(300)
            let replayAll = String(decoding: t2.view.getBufferAsData(), as: UTF8.self)
            check(replayAll.contains("while-detached-g5"), "reattach replays output produced while no view was attached")
            check(replayAll.contains("hello-g5"), "reattach replays earlier scrollback")
            let fullReplayBytes = t2.connection?.replayBytes.value ?? 0
            check(await h.run(t2, "echo after-reattach") != nil, "input works after reattach")
            let offsetAfter = t2.connection?.offset ?? 0
            let raw2 = t2.connection?.rawControl.value ?? []
            t2.close()

            // reattach from a cursor: only bytes after it are replayed
            let t3 = try await h.makeRemote(ptyID: created.id, cursor: offsetAfter)
            check(await h.waitUntil(timeout: .seconds(5)) { t3.replayDone.value }, "cursor reattach: replay_complete")
            await h.pause(200)
            let cursorReplayBytes = t3.connection?.replayBytes.value ?? 0
            check(cursorReplayBytes < 4096, "cursor reattach replays only the tail (\(cursorReplayBytes) bytes)")
            report["replay"] = ["offsetBeforeDetach": offsetBefore, "fullReplayBytes": fullReplayBytes,
                                "offsetAfterReattach": offsetAfter, "cursorReplayBytes": cursorReplayBytes]

            // second controller without takeover, then observer
            let otherEvents = SpikeLocked<[String]>([])
            let other = client.connect(ptyID: created.id, cursor: offsetAfter, takeover: false) { event in
                otherEvents.withLock { $0.append(String("\(event)".prefix(300))) }
            }
            await h.pause(500)
            let observer = client.connect(ptyID: created.id, cursor: offsetAfter, observer: true) { _ in }
            await h.pause(500)
            report["secondController"] = ["raw": other.rawControl.value, "events": otherEvents.value]
            report["observer"] = observer.rawControl.value
            other.close()
            observer.close()
            let takeoverEvents = SpikeLocked<[String]>([])
            let taker = client.connect(ptyID: created.id, cursor: offsetAfter, takeover: true) { event in
                takeoverEvents.withLock { $0.append(String("\(event)".prefix(200))) }
            }
            await h.pause(500)
            report["takeover"] = ["events": takeoverEvents.value, "previousControllerSaw": t3.controlLog.value.suffix(3).map { $0 }]
            taker.close()
            await h.pause(300)

            // retention: produce ~3 MB, then reattach from 0
            let inputAfterTakeover = await h.run(t3, "true", timeout: .seconds(3)) != nil
            report["previousControllerInputAfterTakeoverClosed"] = inputAfterTakeover
            t3.close()
            let tb = try await h.makeRemote(ptyID: created.id, cursor: offsetAfter)
            _ = await h.waitUntil(timeout: .seconds(5)) { tb.replayDone.value }
            check(await h.run(tb, "seq 1 400000", timeout: .seconds(60)) != nil, "bulk output through the socket")
            let endOffset = tb.connection?.offset ?? 0
            tb.close()
            let t4 = try await h.makeRemote(ptyID: created.id, cursor: 0)
            _ = await h.waitUntil(timeout: .seconds(10)) { t4.replayDone.value }
            await h.pause(300)
            let raw4 = t4.connection?.rawControl.value ?? []
            report["retention"] = ["endOffset": endOffset, "replayBytesFromZero": t4.connection?.replayBytes.value ?? 0,
                                   "attached": raw4.first ?? ""]

            // exit notification
            t4.type("exit\r")
            check(await h.waitUntil(timeout: .seconds(10)) { t4.exited.value }, "exited control message on shell exit")
            await h.pause(500)
            report["controlFrames"] = ["firstAttach": raw1, "reattach": raw2, "exit": t4.controlLog.value.suffix(4).map { $0 },
                                       "exitRaw": t4.connection?.rawControl.value.suffix(2).map { $0 } ?? []]
            let afterExit = try await client.listTerminals(sessionID: sid)
            report["listAfterExit"] = afterExit.map { "\($0.id) \($0.status) \($0.exitCode.map(String.init) ?? "nil")" }
            do {
                let exitedInfo = try await client.terminal(created.id)
                report["getAfterExit"] = "\(exitedInfo.status) code \(exitedInfo.exitCode.map(String.init) ?? "nil")"
            } catch {
                report["getAfterExit"] = "\(error)".prefix(120).description
            }
            t4.close()

            // delete (a running one) and check it is gone
            let victim = try await client.createTerminal(
                sessionID: sid, cwd: h.scratch.path, size: SpikeTerminalSize(cols: 80, rows: 24), title: "victim", env: h.remoteEnvironment(),
                command: SpikeShell.loginShell(), args: ["-l"]
            )
            try await client.delete(victim.id)
            let afterDelete = try await client.listTerminals(sessionID: sid)
            check(afterDelete.isEmpty, "delete removes it from the list")
            do {
                _ = try await client.terminal(victim.id)
                check(false, "GET after delete is an error")
            } catch {
                check("\(error)".contains("404"), "GET after delete -> 404")
            }
            let gone = try await client.createTerminal(
                sessionID: sid, cwd: h.scratch.path, size: SpikeTerminalSize(cols: 80, rows: 24), title: "kill", env: h.remoteEnvironment(),
                command: "/bin/sleep", args: ["300"]
            )
            let sleeperPID = gone.pid
            try await client.delete(gone.id)
            await h.pause(500)
            check(kill(pid_t(sleeperPID), 0) != 0, "delete kills a running PTY's process")

            // teardown: no processes left that belong to this server's data root
            let dataRoot = server.dataRoot.path
            await h.stopServer()
            await h.pause(1000)
            let leftovers = spikeProcesses(matching: dataRoot)
            check(leftovers.isEmpty, "no processes left after server stop (\(leftovers.count))")
            report["leftovers"] = leftovers
        } catch {
            failures.append("error: \(error)")
            h.say("error: \(error)")
        }
        report["failures"] = failures
        report["log"] = h.log
        h.write("contract", report)
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Display diagnostics

    func diag() async -> Int32 {
        await h.pause(1500)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let monitor = SpikeFrameMonitor()
        monitor.start(on: h.container)
        await h.pause(1000)
        let frames = monitor.stop()
        let info: Report = [
            "screens": NSScreen.screens.map { "\($0.localizedName) \($0.frame)" },
            "occlusionVisible": h.window.occlusionState.contains(.visible),
            "isVisible": h.window.isVisible, "isKey": h.window.isKeyWindow, "appActive": NSApp.isActive,
            "screenLocked": session["CGSSessionScreenIsLocked"].map { "\($0)" } ?? "nil",
            "onConsole": session["kCGSSessionOnConsoleKey"].map { "\($0)" } ?? "nil",
            "displayAsleep": CGDisplayIsAsleep(CGMainDisplayID()),
            "framesIn1s": frames.intervals.count,
        ]
        h.write("diag", info)
        h.say("\(info)")
        return 0
    }
}
