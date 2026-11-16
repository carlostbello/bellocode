// G5 spike: compatibility checks, verified from the emulator's buffer and input state (and PNG snapshots).
// Usage: TerminalSpike compat --model local|remote [--renderer cg|metal]

import AppKit
import Darwin
import Foundation
import SwiftTerm
import TerminalKit

extension Scenarios {
    final class Checks {
        var results: [Report] = []
        let say: (String) -> Void
        init(say: @escaping (String) -> Void) { self.say = say }

        func record(_ name: String, _ pass: Bool, _ detail: Any = "") {
            results.append(["check": name, "pass": pass, "detail": detail])
            say("\(pass ? "ok  " : "FAIL") \(name) \(detail)")
        }
        var failures: Int { results.count { ($0["pass"] as? Bool) == false } }
    }

    func viewportRows(_ view: TerminalView) -> [TerminalContentRowSnapshot] {
        view.terminalContentSnapshot(region: .viewport)?.rows ?? []
    }

    func screen(_ view: TerminalView) -> String { h.screenText(view).joined(separator: "\n") }

    func lastNonEmptyRow(_ view: TerminalView) -> String {
        h.screenText(view).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    func compat() async -> Int32 {
        let checks = Checks(say: h.say)
        var report: Report = ["model": model, "renderer": renderer]
        do {
            let terminal = try await h.makeTerminal(model: model, renderer: renderer)
            let view = terminal.view
            guard await h.ready(terminal) else { throw SpikeClientError2("shell not ready") }
            let file = h.scratch.appending(path: "vim-sample.txt").path
            try (1...200).map { "line \($0) of the vim sample — ünïcödé 你好" }.joined(separator: "\n")
                .write(toFile: file, atomically: true, encoding: .utf8)

            // TERM and friends as the program sees them
            await h.run(terminal, "clear; echo \"TERM=$TERM COLORTERM=$COLORTERM PROGRAM=$TERM_PROGRAM LANG=$LANG\"")
            let envLine = h.screenText(view).first { $0.hasPrefix("TERM=") } ?? ""
            checks.record("environment", envLine.contains("TERM=xterm-256color") && envLine.contains("truecolor"), envLine)

            // vim: alternate screen, drawing, resize correctness, exit restores the primary screen
            await h.run(terminal, "clear; echo before-vim")
            terminal.type("vim -u NONE -N -i NONE \(file)\r")
            _ = await h.waitUntil(timeout: .seconds(5)) { self.screen(view).contains("line 1 of the vim sample") }
            await h.pause(300)
            let altInVim = view.terminalInputStateSnapshot()?.isAlternateBuffer ?? false
            checks.record("vim draws file", screen(view).contains("line 1 of the vim sample") && screen(view).contains("你好"))
            checks.record("vim uses alternate screen", altInVim)
            report["vimSnapshot"] = h.snapshot(view, "compat-\(tag)-vim")
            var resizeResults: [Report] = []
            for size in [NSSize(width: 600, height: 300), NSSize(width: 1300, height: 820), NSSize(width: 420, height: 180), h.terminalFrame.size] {
                view.setFrameSize(size)
                await h.pause(500)
                let dims = view.terminalDimensions
                terminal.type(":echo &columns . 'x' . &lines\r")
                let expected = "\(dims.cols)x\(dims.rows)"
                let ok = await h.waitUntil(timeout: .seconds(3)) { self.lastNonEmptyRow(view).contains(expected) }
                let lastRow = lastNonEmptyRow(view)
                // vim's status/echo line is the last row and the file's first line is still at the top.
                let top = h.screenText(view).first ?? ""
                resizeResults.append(["view": expected, "vimSays": lastRow.trimmingCharacters(in: .whitespaces),
                                      "topRow": String(top.prefix(40)), "ok": ok && top.hasPrefix("line 1")])
                if size.width == 420 { report["vimResizedSnapshot"] = h.snapshot(view, "compat-\(tag)-vim-small") }
            }
            if let remote = terminal as? SpikeRemoteTerminal {
                let info = try await remote.client.terminal(remote.ptyID)
                report["serverSizeAfterResizes"] = "\(info.size.cols)x\(info.size.rows)"
            }
            checks.record("resize while vim runs (4 sizes)", resizeResults.allSatisfy { ($0["ok"] as? Bool) == true }, resizeResults)
            terminal.type(":q!\r")
            _ = await h.waitUntil(timeout: .seconds(3)) { !(view.terminalInputStateSnapshot()?.isAlternateBuffer ?? true) }
            await h.pause(200)
            checks.record("vim exit restores primary screen", screen(view).contains("before-vim") && !(view.terminalInputStateSnapshot()?.isAlternateBuffer ?? true))

            // top: full-screen refresh, resize, quit
            terminal.type("top -s 1 -n 20\r")
            _ = await h.waitUntil(timeout: .seconds(5)) { self.screen(view).contains("Processes:") }
            await h.pause(1200)
            view.setFrameSize(NSSize(width: 1100, height: 700))
            await h.pause(2200)
            let topScreen = h.screenText(view)
            let topDims = view.terminalDimensions
            let topOK = topScreen.first?.hasPrefix("Processes:") == true && topScreen.contains { $0.contains("PID") }
            checks.record("top renders and redraws after resize", topOK, "\(topDims.cols)x\(topDims.rows) first: \(topScreen.first?.prefix(50) ?? "")")
            report["topSnapshot"] = h.snapshot(view, "compat-\(tag)-top")
            terminal.type("q")
            await h.pause(500)
            view.setFrameSize(h.terminalFrame.size)
            await h.pause(300)
            report["tmux"] = "not installed; htop not installed"

            // 24-bit and 256 colour
            await h.run(terminal, "clear; printf '\\033[38;2;255;100;0mTRUECOLOR\\033[0m \\033[48;2;10;20;30mBG\\033[0m \\033[38;5;201mC256\\033[0m\\n'")
            let colourRow = viewportRows(view).first { $0.text.contains("TRUECOLOR") }
            let trueCell = colourRow?.cells.first { $0.text == "T" }
            let bgCell = colourRow.flatMap { row in row.cells.first { $0.text == "B" } }
            let c256Cell = colourRow.flatMap { row in
                row.cells.indices.first { $0 + 1 < row.cells.count && row.cells[$0].text == "C" && row.cells[$0 + 1].text == "2" }.map { row.cells[$0] }
            }
            checks.record("24-bit foreground", trueCell?.attribute.fg == .trueColor(red: 255, green: 100, blue: 0), "\(trueCell?.attribute.fg as Any)")
            checks.record("24-bit background", bgCell?.attribute.bg == .trueColor(red: 10, green: 20, blue: 30), "\(bgCell?.attribute.bg as Any)")
            checks.record("256 colour", c256Cell?.attribute.fg == .ansi256(code: 201), "\(c256Cell?.attribute.fg as Any)")

            // Wide, emoji, combining, ZWJ, flags
            await h.run(terminal, "clear; printf 'W:你好|E:👍🏽|C:e\\xcc\\x81|Z:👨‍👩‍👧|F:🇺🇸|end\\n'")
            if let row = viewportRows(view).first(where: { $0.text.hasPrefix("W:") }) {
                let cells = row.cells.filter { !$0.isBlank }.map { "\($0.text)/\($0.width)" }
                let widths = Dictionary(row.cells.filter { !$0.isBlank }.map { ($0.text, $0.width) }, uniquingKeysWith: { a, _ in a })
                checks.record("CJK is double width", widths["你"] == 2 && widths["好"] == 2)
                checks.record("emoji with skin tone is one double-width cell", widths["👍🏽"] == 2, cells.joined(separator: " "))
                checks.record("combining mark joins its base", widths["e\u{301}"] == 1 || widths["é"] == 1)
                checks.record("ZWJ family is one cluster", widths["👨‍👩‍👧"] == 2)
                checks.record("flag is one double-width cluster", widths["🇺🇸"] == 2)
                checks.record("columns line up after clusters", row.text.hasSuffix("|end"), row.text)
            }
            report["unicodeSnapshot"] = h.snapshot(view, "compat-\(tag)-unicode")

            // Alternate screen by escape sequence
            terminal.type("printf '\\033[?1049h'; printf 'IN-\\101LT'; sleep 1; printf '\\033[?1049l'\r")
            let sawAlt = await h.waitUntil(timeout: .seconds(3)) { view.terminalInputStateSnapshot()?.isAlternateBuffer == true }
            let altText = screen(view).contains("IN-ALT")
            let leftAlt = await h.waitUntil(timeout: .seconds(4)) { view.terminalInputStateSnapshot()?.isAlternateBuffer == false }
            checks.record("alternate screen enter/leave (1049)", sawAlt && altText && leftAlt && !screen(view).contains("IN-ALT"))

            // Mouse reporting (SGR 1006): cat -v shows what the view sends for a click
            await h.run(terminal, "clear")
            terminal.type("printf '\\033[?1000h\\033[?1006h'; cat -v\r")
            _ = await h.waitUntil(timeout: .seconds(3)) { view.terminalInputStateSnapshot()?.mouseMode != .off }
            let mouseMode = view.terminalInputStateSnapshot()?.mouseMode
            let point = h.cellPoint(view, col: 9, row: 5)
            h.mouseDirect(.leftMouseDown, at: point, in: view)
            h.mouseDirect(.leftMouseUp, at: point, in: view)
            terminal.type("\r")
            let mouseOK = await h.waitUntil(timeout: .seconds(3)) { self.screen(view).contains("[<0;10;6M") }
            checks.record("mouse reporting (SGR)", mouseOK, "mode \(mouseMode.map { "\($0)" } ?? "nil"); screen: \(h.screenText(view).filter { !$0.isEmpty })")
            terminal.type("\u{3}")
            await h.run(terminal, "printf '\\033[?1000l\\033[?1006l'")

            // Bracketed paste
            await h.run(terminal, "clear")
            terminal.type("printf '\\033[?2004h'; cat -v\r")
            _ = await h.waitUntil(timeout: .seconds(3)) { view.terminalInputStateSnapshot()?.bracketedPasteMode == true }
            view.pasteText("pasted-g5")
            terminal.type("\r")
            let pasteOK = await h.waitUntil(timeout: .seconds(3)) { self.screen(view).contains("^[[200~pasted-g5^[[201~") }
            checks.record("bracketed paste", pasteOK, h.screenText(view).first { $0.contains("pasted") } ?? "")
            terminal.type("\u{3}")
            await h.run(terminal, "printf '\\033[?2004l'")

            // OSC 8 hyperlink: command-click opens through the delegate (BelloCode routes it)
            var opened: [String] = []
            setLinkHandler(terminal) { opened.append($0) }
            await h.run(terminal, "clear; printf '\\033]8;;https://example.com/osc8-g5\\033\\\\OSC8LINK\\033]8;;\\033\\\\ and https://example.org/implicit-g5 here\\n'")
            if let row = h.screenText(view).firstIndex(where: { $0.contains("OSC8LINK") }) {
                let linkPoint = h.cellPoint(view, col: 2, row: row)
                h.mouse(.mouseMoved, at: linkPoint, in: view, modifiers: .command)
                h.mouse(.leftMouseDown, at: linkPoint, in: view, modifiers: .command)
                h.mouse(.leftMouseUp, at: linkPoint, in: view, modifiers: .command)
                await h.pause(300)
                let implicitCol = (h.screenText(view)[row].range(of: "https://example.org").map { h.screenText(view)[row].distance(from: h.screenText(view)[row].startIndex, to: $0.lowerBound) } ?? 0) + 5
                let implicitPoint = h.cellPoint(view, col: implicitCol, row: row)
                h.mouse(.mouseMoved, at: implicitPoint, in: view, modifiers: .command)
                h.mouse(.leftMouseDown, at: implicitPoint, in: view, modifiers: .command)
                h.mouse(.leftMouseUp, at: implicitPoint, in: view, modifiers: .command)
                await h.pause(300)
            }
            checks.record("OSC 8 hyperlink opens via delegate", opened.contains("https://example.com/osc8-g5"), opened)
            checks.record("implicit URL detection opens via delegate", opened.contains { $0.contains("example.org/implicit-g5") }, opened)

            // OSC 52: local LocalProcessTerminalView would write the general pasteboard (not overridable); only the
            // remote view (own TerminalViewDelegate) is exercised, and it blocks.
            if let remote = terminal as? SpikeRemoteTerminal {
                let pasteboardBefore = NSPasteboard.general.changeCount
                await h.run(terminal, "printf '\\033]52;c;b3NjNTItZzU=\\007'")
                await h.pause(200)
                let blocked = remote.controlLog.value.contains { $0.hasPrefix("osc52-blocked") }
                checks.record("OSC 52 reaches delegate and is blocked", blocked && NSPasteboard.general.changeCount == pasteboardBefore)
            } else {
                report["osc52Local"] = "not run: LocalProcessTerminalView.clipboardCopy writes NSPasteboard.general and is not open for override"
            }

            // OSC 7 cwd and OSC 0/2 title
            await h.run(terminal, "printf '\\033]7;file://localhost/private/tmp/g5-osc7\\007\\033]2;g5-title\\007'")
            await h.pause(200)
            let (directory, title) = reported(terminal)
            checks.record("OSC 7 working directory", directory?.contains("/private/tmp/g5-osc7") == true, directory ?? "nil")
            checks.record("OSC 2 title", title == "g5-title", title)

            // OSC 133 shell integration marks
            await h.run(terminal, "clear; printf '\\033]133;A\\007$ \\033]133;B\\007ls\\n\\033]133;C\\007out\\n\\033]133;D;0\\007'")
            let marks = terminal.markers.seen(code: 133).map(\.payload)
            checks.record("OSC 133 marks parsed (A/B/C/D)", ["A", "B", "C", "D;0"].allSatisfy(marks.contains), marks)
            report["compatSnapshotFinal"] = h.snapshot(view, "compat-\(tag)-final")
            terminal.close()
        } catch {
            report["error"] = "\(error)"
        }
        report["checks"] = checks.results
        report["failures"] = checks.failures
        h.write("compat-\(tag)", report)
        return report["error"] == nil && checks.failures == 0 ? 0 : 1
    }

    func setLinkHandler(_ terminal: any SpikeTerminal, _ handler: @escaping (String) -> Void) {
        if let local = terminal as? SpikeLocalTerminal { local.onLink = handler }
        if let remote = terminal as? SpikeRemoteTerminal { remote.onLink = handler }
    }

    func reported(_ terminal: any SpikeTerminal) -> (String?, String) {
        if let local = terminal as? SpikeLocalTerminal { return (local.reportedDirectory, local.title) }
        if let remote = terminal as? SpikeRemoteTerminal { return (remote.reportedDirectory, remote.title) }
        return (nil, "")
    }
}
