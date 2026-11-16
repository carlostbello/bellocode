// G5 spike: app-restart persistence (model b) and product hooks (selection, find, links, theme, font, many views).
// Usage: TerminalSpike restart1 ; TerminalSpike restart2      (two separate processes; the server outlives the first)
//        TerminalSpike hooks --model local|remote

import AppKit
import Darwin
import Foundation
import SwiftTerm
import TerminalKit

extension Scenarios {
    var restartStateURL: URL { h.paths.reports.appending(path: "restart-state.json") }

    /// Phase 1: a server in its own session, a shell with state, then this process exits without stopping it.
    func restart1() async -> Int32 {
        do {
            let port = Int.random(in: 47_000...48_999)
            let password = SpikeServer.randomPassword()
            let dataRoot = h.paths.root.appending(path: "build/spikes/G5/oc-restart")
            try? FileManager.default.removeItem(at: dataRoot)
            let server = try await SpikeServer.startDetached(paths: h.paths, dataRoot: dataRoot, port: port, password: password)
            let client = server.client
            let sid = try await client.createSession(directory: h.scratch.path, title: "g5-restart")
            let info = try await client.createTerminal(
                sessionID: sid, cwd: h.scratch.path, size: SpikeTerminalSize(cols: 100, rows: 30), title: "restart",
                env: h.remoteEnvironment(), command: SpikeShell.loginShell(), args: ["-l"]
            )
            let terminal = SpikeRemoteTerminal(frame: h.terminalFrame, client: client, ptyID: info.id, scrollback: 10_000)
            h.container.addSubview(terminal.view)
            terminal.attach()
            guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }
            await h.run(terminal, "export G5_STATE=kept-across-restart; echo before-restart-g5")
            // Output produced after this process is gone must also be retained.
            terminal.type("(sleep 2; echo produced-while-app-gone) &\r")
            await h.pause(300)
            let state: [String: Any] = [
                "port": port, "password": password, "pid": Int(server.pid), "dataRoot": dataRoot.path,
                "ptyID": info.id, "sessionID": sid, "offset": terminal.connection?.offset ?? 0, "shellPID": info.pid,
                "daemonPID": server.daemonPID().map(Int.init) ?? -1,
            ]
            let data = try JSONSerialization.data(withJSONObject: state)
            FileManager.default.createFile(atPath: restartStateURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            h.say("phase 1 done: server \(server.pid) left running, pty \(info.id)")
            terminal.close()
            return 0
        } catch {
            h.say("error \(error)")
            return 1
        }
    }

    /// Phase 2: a new process adopts the server, reattaches, verifies replay and shell state, then cleans up.
    func restart2() async -> Int32 {
        let checks = Checks(say: h.say)
        var report: Report = [:]
        guard let data = try? Data(contentsOf: restartStateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = state["port"] as? Int, let password = state["password"] as? String, let pid = state["pid"] as? Int,
              let ptyID = state["ptyID"] as? String, let dataRootPath = state["dataRoot"] as? String
        else { h.say("no restart state; run restart1 first"); return 2 }
        let dataRoot = URL(fileURLWithPath: dataRootPath)
        try? FileManager.default.removeItem(at: restartStateURL)
        guard let server = SpikeServer.adopt(paths: h.paths, dataRoot: dataRoot, port: port, password: password, pid: pid_t(pid)) else {
            h.say("server pid \(pid) is not our opencode; nothing adopted")
            return 1
        }
        do {
            let client = server.client
            await h.pause(2500)
            let info = try await client.terminal(ptyID)
            checks.record("PTY still running after the app process exited", info.status == "running" && info.pid == state["shellPID"] as? Int)
            let terminal = SpikeRemoteTerminal(frame: h.terminalFrame, client: client, ptyID: ptyID, scrollback: 10_000)
            h.container.addSubview(terminal.view)
            terminal.attach(cursor: 0)
            _ = await h.waitUntil(timeout: .seconds(5)) { terminal.replayDone.value }
            await h.pause(300)
            let text = String(decoding: terminal.view.getBufferAsData(), as: UTF8.self)
            checks.record("replay restores output from before the restart", text.contains("before-restart-g5"))
            checks.record("replay includes output produced while no app was running", text.contains("produced-while-app-gone"))
            await h.run(terminal, "echo state=$G5_STATE")
            checks.record("same shell process (environment kept)", h.screenText(terminal.view).contains { $0.contains("state=kept-across-restart") })
            report["snapshot"] = h.snapshot(terminal.view, "restart-reattached")
            let cursor = terminal.connection?.offset ?? 0
            terminal.close()
            let tail = SpikeRemoteTerminal(frame: h.terminalFrame, client: client, ptyID: ptyID, scrollback: 10_000)
            h.container.addSubview(tail.view)
            tail.attach(cursor: cursor)
            _ = await h.waitUntil(timeout: .seconds(5)) { tail.replayDone.value }
            checks.record("reattach from saved cursor replays nothing old", (tail.connection?.replayBytes.value ?? -1) == 0)
            tail.close()
            try await client.delete(ptyID)
        } catch {
            checks.record("no error", false, "\(error)")
        }
        // Stop the server we started (verified pid), then confirm nothing of ours is left.
        await server.stop()
        await h.pause(1500)
        let daemon = state["daemonPID"] as? Int ?? -1
        let leftovers = spikeProcesses(matching: dataRoot.path)
        checks.record("server, pty daemon and shell gone after stop", leftovers.isEmpty && (daemon <= 0 || kill(pid_t(daemon), 0) != 0)
            && kill(pid_t(state["shellPID"] as? Int ?? 0), 0) != 0, leftovers)
        try? FileManager.default.removeItem(at: dataRoot)
        report["checks"] = checks.results
        h.write("restart", report)
        return checks.failures == 0 ? 0 : 1
    }

    // MARK: - Product hooks

    func hooks() async -> Int32 {
        let checks = Checks(say: h.say)
        var report: Report = ["model": model]
        do {
            let terminal = try await h.makeTerminal(model: model, renderer: "cg")
            let view = terminal.view
            guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }

            // Find in scrollback
            await h.run(terminal, "clear; echo needle-g5-early; seq 1 3000")
            let found = view.findNext("needle-g5-early")
            let summary = view.searchMatchSummary("needle-g5-early")
            checks.record("find in scrollback", found && summary.total >= 1, "total \(summary.total)")
            view.scrollTo(row: Int.max)

            // Select and copy (selection API only; the pasteboard is never written in the spike)
            await h.run(terminal, "clear; echo select-me-g5")
            view.selectAll()
            let selection = view.getSelection() ?? ""
            checks.record("select all + getSelection", selection.contains("select-me-g5"), "\(selection.count) chars")
            var composer: [String] = []
            let sendToComposer: (String) -> Void = { composer.append($0) }   // the product callback
            if let text = view.getSelection(), !text.isEmpty { sendToComposer(text) }
            checks.record("send selection to composer callback", composer.first?.contains("select-me-g5") == true)

            // Theme from a colour table
            let palette: [SwiftTerm.Color] = (0..<16).map { index in
                let v = UInt16(index * 4000)
                return SwiftTerm.Color(red: v, green: 65535 - v, blue: UInt16(30000))
            }
            view.installColors(palette)
            view.nativeBackgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
            view.nativeForegroundColor = NSColor(srgbRed: 0.85, green: 0.87, blue: 0.90, alpha: 1)
            await h.run(terminal, "clear; printf '\\033[31mred-slot\\033[0m \\033[34mblue-slot\\033[0m themed\\n'")
            report["themeSnapshot"] = h.snapshot(view, "hooks-\(model)-theme")
            // The default background is the view's layer colour (cacheDisplay snapshots do not capture layer
            // backgrounds, so the PNG shows white there); check the layer, and the palette via the PNG.
            var backgroundOK = false
            if let cg = view.layer?.backgroundColor, let color = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) {
                backgroundOK = abs(color.redComponent - 0.10) < 0.02 && abs(color.blueComponent - 0.16) < 0.02
                report["themeLayerBackground"] = [color.redComponent, color.greenComponent, color.blueComponent].map { h.round(Double($0), 3) }
            }
            checks.record("theme background applied (layer colour)", backgroundOK, report["themeLayerBackground"] ?? "no layer")

            // Font and size change -> grid and PTY size follow
            let before = view.terminalDimensions
            view.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
            await h.pause(400)
            let after = view.terminalDimensions
            await h.run(terminal, "stty size > \(h.scratch.path)/stty-font.txt")
            let stty = (try? String(contentsOfFile: "\(h.scratch.path)/stty-font.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            checks.record("font change resizes grid and PTY", after.cols < before.cols && stty == "\(after.rows) \(after.cols)",
                          "\(before.cols)x\(before.rows) -> \(after.cols)x\(after.rows), stty \(stty)")
            view.font = SpikeTerminalStyle.font
            terminal.close()

            // Many terminals in one window, then close them all: views freed, shells gone
            let footprintBefore = SpikeProcessStats.footprintMiB()
            var many: [any SpikeTerminal] = []
            var weakViews: [() -> Bool] = []
            var shellPIDs: [pid_t] = []
            for index in 0..<8 {
                let frame = NSRect(x: (index % 4) * 340, y: (index / 4) * 300, width: 330, height: 280)
                let t: any SpikeTerminal = model == "remote" ? try await h.makeRemote(frame: frame) : h.makeLocal(frame: frame)
                _ = await h.ready(t)
                if let local = t as? SpikeLocalTerminal { shellPIDs.append(local.shellPID) }
                weak var weakView = t.view
                weakViews.append { weakView == nil }
                many.append(t)
            }
            report["manySnapshot"] = h.snapshot(h.container, "hooks-\(model)-many")
            let footprintMany = SpikeProcessStats.footprintMiB()
            many.forEach { $0.close() }
            many.removeAll()
            h.window.makeFirstResponder(nil)
            await h.pause(1500)
            let freed = weakViews.filter { $0() }.count
            let shellsAlive = shellPIDs.filter { kill($0, 0) == 0 }.count
            report["many"] = ["footprintBeforeMiB": h.round(footprintBefore, 1), "footprintWith8MiB": h.round(footprintMany, 1),
                              "viewsFreed": freed, "shellsAlive": shellsAlive]
            checks.record("8 terminals closed: shells gone", shellsAlive == 0, "\(shellsAlive) alive")
            checks.record("8 terminals closed: views deallocated", freed == 8, "\(freed)/8 freed")
            if let server = h.server {
                let list = try await server.client.listTerminals(sessionID: h.sessionID ?? "")
                report["remotePTYsStillOnServerAfterViewClose"] = list.count
            }
        } catch {
            report["error"] = "\(error)"
        }
        report["checks"] = checks.results
        h.write("hooks-\(model)", report)
        return report["error"] == nil && checks.failures == 0 ? 0 : 1
    }
}
