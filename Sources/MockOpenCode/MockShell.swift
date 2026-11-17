import Foundation

/// A tiny scripted shell behind the mock's persistent PTYs, so terminal features can be tested offline.
///
/// It echoes typed input, edits the line (Backspace, Ctrl-C, Ctrl-U), ignores cursor-key sequences, strips bracketed
/// paste markers, and on Return runs one of a handful of commands. Its prompt is wrapped in OSC 133 marks and it
/// reports the directory with OSC 7, like a configured zsh.
///
/// Commands: `echo …`, `pwd`, `cd DIR`, `exit [N]`, `title TEXT` (OSC 2), `seq N`, `flood N` (N bytes of 64-column
/// lines), `size` (the grid), `link URL [TEXT]` (OSC 8), `clip TEXT` (OSC 52 write), `colors` (ANSI palette),
/// `ls`, `clear`, `fg NAME` (sets the foreground process name until the next prompt), `true`, `false`.
struct MockShell: Sendable {
    struct Effect: Sendable, Equatable {
        var output = Data()
        var exitCode: Int?
        var title: String?
        var foregroundProcess: String??
    }

    private(set) var cwd: String
    private var line: [UInt8] = []
    private var escape: [UInt8]?
    private var lastStatus = 0

    init(cwd: String) {
        self.cwd = cwd
    }

    /// The first output: directory report and prompt.
    mutating func start() -> Effect {
        var effect = Effect()
        effect.output.append(osc7)
        effect.output.append(prompt)
        return effect
    }

    mutating func input(_ bytes: Data, size: (cols: Int, rows: Int)) -> Effect {
        var effect = Effect()
        for byte in bytes {
            if var sequence = escape {
                sequence.append(byte)
                escape = sequence
                if let finished = finishEscape(sequence) {
                    escape = nil
                    if finished == "[200~" || finished == "[201~" { continue }
                }
                continue
            }
            switch byte {
            case 0x1B:
                escape = []
            case 0x0D, 0x0A:
                effect.output.append(contentsOf: [0x0D, 0x0A])
                let command = String(decoding: line, as: UTF8.self)
                line.removeAll()
                run(command, size: size, into: &effect)
                if effect.exitCode != nil { return effect }
                effect.output.append(osc133("D;\(lastStatus)"))
                effect.output.append(osc7)
                effect.output.append(prompt)
            case 0x7F, 0x08:
                if !line.isEmpty {
                    line.removeLast()
                    effect.output.append(Data("\u{8} \u{8}".utf8))
                }
            case 0x03:
                line.removeAll()
                effect.output.append(Data("^C\r\n".utf8))
                lastStatus = 130
                effect.output.append(osc133("D;130"))
                effect.output.append(prompt)
            case 0x15:
                effect.output.append(Data(String(repeating: "\u{8} \u{8}", count: line.count).utf8))
                line.removeAll()
            case 0x04 where line.isEmpty:
                effect.exitCode = 0
                return effect
            case 0x20...0x7E, 0x80...0xFF:
                line.append(byte)
                effect.output.append(byte)
            default:
                break
            }
        }
        return effect
    }

    /// The escape sequence's text once complete (CSI ends with a final byte 0x40–0x7E; other ESC x are two bytes).
    private func finishEscape(_ sequence: [UInt8]) -> String? {
        guard let first = sequence.first else { return nil }
        if first == UInt8(ascii: "[") {
            guard sequence.count > 1, let last = sequence.last, (0x40...0x7E).contains(last) else { return nil }
            return String(decoding: sequence, as: UTF8.self)
        }
        if first == UInt8(ascii: "O") { return sequence.count >= 2 ? String(decoding: sequence, as: UTF8.self) : nil }
        return String(decoding: sequence, as: UTF8.self)
    }

    private mutating func run(_ commandLine: String, size: (cols: Int, rows: Int), into effect: inout Effect) {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        effect.output.append(osc133("C"))
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let rest = trimmed.dropFirst(words[0].count).trimmingCharacters(in: .whitespaces)
        var out = ""
        lastStatus = 0
        switch words[0] {
        case "echo": out = rest + "\r\n"
        case "pwd": out = cwd + "\r\n"
        case "cd":
            let target = rest.isEmpty ? "/" : rest
            cwd = target.hasPrefix("/") ? target : (cwd as NSString).appendingPathComponent(target)
        case "exit":
            effect.exitCode = Int(words.dropFirst().first ?? "0") ?? 0
            return
        case "title":
            out = "\u{1B}]2;\(rest)\u{7}"
            effect.title = rest
        case "seq":
            let count = min(Int(words.dropFirst().first ?? "10") ?? 10, 5_000_000)
            var data = Data()
            data.reserveCapacity(count * 7)
            for number in 1...max(1, count) { data.append(Data("\(number)\r\n".utf8)) }
            effect.output.append(data)
        case "flood":
            let bytes = min(Int(words.dropFirst().first ?? "1024") ?? 1024, 64 << 20)
            let row = Data((String(repeating: "x", count: 62) + "\r\n").utf8)
            var data = Data()
            data.reserveCapacity(bytes)
            while data.count + row.count <= bytes { data.append(row) }
            if data.count < bytes { data.append(Data(repeating: UInt8(ascii: "y"), count: bytes - data.count)) }
            effect.output.append(data)
        case "size": out = "\(size.cols)x\(size.rows)\r\n"
        case "link":
            let url = words.dropFirst().first ?? "https://example.com"
            let text = words.count > 2 ? words.dropFirst(2).joined(separator: " ") : url
            out = "\u{1B}]8;;\(url)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\\r\n"
        case "clip":
            out = "\u{1B}]52;c;\(Data(rest.utf8).base64EncodedString())\u{7}"
        case "colors":
            var lines: [String] = []
            for base in [30, 90] {
                lines.append((0..<8).map { "\u{1B}[\(base + $0)m██\u{1B}[0m" }.joined(separator: " "))
            }
            lines.append("\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[4munderline\u{1B}[0m \u{1B}[31merror\u{1B}[0m \u{1B}[32mok\u{1B}[0m \u{1B}[33mwarn\u{1B}[0m")
            out = lines.joined(separator: "\r\n") + "\r\n"
        case "ls":
            out = "\u{1B}[1;34mSources\u{1B}[0m  \u{1B}[1;34mTests\u{1B}[0m  \u{1B}[1;34mdocs\u{1B}[0m  Package.swift  README.md  \u{1B}[32mmake-app.sh\u{1B}[0m\r\n"
        case "clear": out = "\u{1B}[H\u{1B}[2J"
        case "fg":
            effect.foregroundProcess = .some(words.dropFirst().first)
        case "true": break
        case "false": lastStatus = 1
        default:
            out = "mock-sh: command not found: \(words[0])\r\n"
            lastStatus = 127
        }
        effect.output.append(Data(out.utf8))
    }

    private var prompt: Data {
        let name = (cwd as NSString).lastPathComponent
        return osc133("A") + Data("\u{1B}[32m➜\u{1B}[0m \u{1B}[36m\(name.isEmpty ? "/" : name)\u{1B}[0m $ ".utf8) + osc133("B")
    }

    private var osc7: Data { Data("\u{1B}]7;file://localhost\(cwd)\u{7}".utf8) }

    private func osc133(_ body: String) -> Data { Data("\u{1B}]133;\(body)\u{7}".utf8) }
}
