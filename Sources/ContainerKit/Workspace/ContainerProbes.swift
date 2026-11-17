import Foundation

/// A TCP port something listens on inside a workspace container.
public struct ListeningPort: Sendable, Equatable, Hashable, Codable {
    public var port: Int
    /// The bound address as text: `127.0.0.1`, `0.0.0.0`, `::1`, `::`.
    public var address: String
    public var pid: Int?
    /// The process name (`/proc/<pid>/comm`), when the listener belongs to the commands' user.
    public var process: String?

    public init(port: Int, address: String, pid: Int? = nil, process: String? = nil) {
        self.port = port
        self.address = address
        self.pid = pid
        self.process = process
    }

    /// Where a relay inside the container connects: loopback of the family it listens on.
    public var relayHost: String { address.contains(":") ? "::1" : "127.0.0.1" }
    /// Bound to every interface of the container (reachable from other containers on the bridge).
    public var isWildcard: Bool { address == "0.0.0.0" || address == "::" }
}

/// A process in a workspace container (from `/proc`).
public struct ContainerProcess: Sendable, Equatable, Hashable {
    public var pid: Int
    public var ppid: Int
    public var command: String
}

/// Scripts BelloCode runs inside workspace containers, and pure parsers for their output. Every script is POSIX `sh`
/// reading `/proc`, so any Linux image with `/bin/sh` works; none prints file contents or environment values.
public enum ContainerProbes {
    /// Prints `/proc/net/tcp` and `/proc/net/tcp6`, then `PID INODE COMM` for every socket descriptor the user can see.
    public static let listeningPortsScript: [String] = ["/bin/sh", "-c", """
        echo '#tcp'; cat /proc/net/tcp 2>/dev/null
        echo '#tcp6'; cat /proc/net/tcp6 2>/dev/null
        echo '#fd'
        for p in /proc/[0-9]*; do
          c=$(cat "$p/comm" 2>/dev/null) || continue
          for f in "$p"/fd/*; do
            l=$(readlink "$f" 2>/dev/null) || continue
            case "$l" in socket:*) echo "${p#/proc/} ${l#socket:} $c";; esac
          done
        done
        """]

    /// Parses `listeningPortsScript` output into listeners, one per (address, port), lowest port first.
    public static func parseListeningPorts(_ output: String) -> [ListeningPort] {
        var section = ""
        var listeners: [(address: String, port: Int, inode: String)] = []
        var owners: [String: (pid: Int, comm: String)] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                section = line
                continue
            }
            switch section {
            case "#tcp", "#tcp6":
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count > 9, fields[3] == "0A" else { continue }  // 0A = LISTEN
                let local = fields[1].split(separator: ":")
                guard local.count == 2, let port = Int(local[1], radix: 16) else { continue }
                let address = section == "#tcp" ? ipv4(String(local[0])) : ipv6(String(local[0]))
                listeners.append((address, port, String(fields[9])))
            case "#fd":
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count >= 2, let pid = Int(fields[0]) else { continue }
                let inode = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if owners[inode] == nil { owners[inode] = (pid, fields.count > 2 ? String(fields[2]) : "") }
            default:
                continue
            }
        }
        var seen = Set<String>()
        var result: [ListeningPort] = []
        for listener in listeners {
            let key = "\(listener.address) \(listener.port)"
            guard seen.insert(key).inserted else { continue }
            let owner = owners[listener.inode]
            result.append(ListeningPort(port: listener.port, address: listener.address, pid: owner?.pid,
                                        process: owner.map(\.comm).flatMap { $0.isEmpty ? nil : $0 }))
        }
        return result.sorted { ($0.port, $0.address) < ($1.port, $1.address) }
    }

    /// Little-endian hex IPv4 from /proc/net/tcp.
    static func ipv4(_ hex: String) -> String {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return hex }
        return [value & 0xFF, value >> 8 & 0xFF, value >> 16 & 0xFF, value >> 24 & 0xFF].map(String.init).joined(separator: ".")
    }

    /// /proc/net/tcp6 addresses: four little-endian 32-bit words. Only the forms that matter are named.
    static func ipv6(_ hex: String) -> String {
        switch hex {
        case "00000000000000000000000000000000": return "::"
        case "00000000000000000000000001000000": return "::1"
        default:
            // IPv4-mapped (::ffff:a.b.c.d) is reported as the IPv4 address.
            if hex.hasPrefix("0000000000000000FFFF0000") { return ipv4(String(hex.suffix(8))) }
            return hex
        }
    }

    /// Prints `PID PPID COMMAND` for every process.
    public static let processListScript: [String] = ["/bin/sh", "-c", """
        for p in /proc/[0-9]*; do
          s=$(cat "$p/stat" 2>/dev/null) || continue
          r=${s##*) }; set -- $r
          a=$(tr '\\000' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-200)
          echo "${p#/proc/} $2 ${a:-[$(cat "$p/comm" 2>/dev/null)]}"
        done
        """]

    public static func parseProcesses(_ output: String) -> [ContainerProcess] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int(fields[0]), let ppid = Int(fields[1]) else { return nil }
            return ContainerProcess(pid: pid, ppid: ppid, command: fields.count > 2 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : "")
        }.sorted { $0.pid < $1.pid }
    }

    /// Kills processes left behind by finished or cancelled commands: everything re-parented to the container's init
    /// (tini, PID 1) except the keep-alive `sleep infinity`, i.e. daemons that escaped their command's process group
    /// (`setsid`, double forks). Run only while no exec is running, so nothing a live command owns is touched. Prints
    /// the number killed. Runs as the commands' user (it can signal only their processes).
    public static let reaperScript: [String] = ["/bin/sh", "-c", """
        n=0
        for p in /proc/[0-9]*; do
          pid=${p#/proc/}
          [ "$pid" = 1 ] && continue
          s=$(cat "$p/stat" 2>/dev/null) || continue
          r=${s##*) }; set -- $r
          [ "$2" = 1 ] || continue
          a=$(tr '\\000' ' ' < "$p/cmdline" 2>/dev/null)
          case "$a" in "sleep infinity"*) continue;; esac
          kill -TERM "$pid" 2>/dev/null && n=$((n+1))
        done
        [ $n -gt 0 ] && sleep 1
        for p in /proc/[0-9]*; do
          pid=${p#/proc/}
          [ "$pid" = 1 ] && continue
          s=$(cat "$p/stat" 2>/dev/null) || continue
          r=${s##*) }; set -- $r
          [ "$2" = 1 ] || continue
          a=$(tr '\\000' ' ' < "$p/cmdline" 2>/dev/null)
          case "$a" in "sleep infinity"*) continue;; esac
          kill -KILL "$pid" 2>/dev/null
        done
        echo $n
        """]

    /// Raises inotify events for host-side changes: `touch -m -r f f` sets a file's modification time to itself (no
    /// change to content or metadata) and the kernel still reports IN_ATTRIB to watchers. Missing paths are skipped.
    public static func touchScript(_ paths: [String]) -> [String] {
        ["/bin/sh", "-c", "for f; do [ -e \"$f\" ] && touch -c -m -r \"$f\" \"$f\" 2>/dev/null; done; exit 0", "bellocode-touch"] + paths
    }

    /// Prints what the image offers, one `name=value` per line, for the agent's guidance and the Environment pane.
    public static let toolInventoryScript: [String] = ["/bin/sh", "-c", """
        . /etc/os-release 2>/dev/null; echo "os=${PRETTY_NAME:-unknown}"
        echo "arch=$(uname -m)"
        for t in bash git python3 node npm bun go cargo java ruby make gcc curl rg socat nc; do
          command -v "$t" >/dev/null 2>&1 && echo "tool=$t"
        done
        exit 0
        """]

    public struct ToolInventory: Sendable, Equatable, Codable {
        public var os: String
        public var arch: String
        public var tools: [String]
        public init(os: String, arch: String, tools: [String]) {
            self.os = os
            self.arch = arch
            self.tools = tools
        }
    }

    public static func parseInventory(_ output: String) -> ToolInventory {
        var os = "unknown", arch = "", tools: [String] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("os=") { os = String(line.dropFirst(3)) }
            if line.hasPrefix("arch=") { arch = String(line.dropFirst(5)) }
            if line.hasPrefix("tool=") { tools.append(String(line.dropFirst(5))) }
        }
        return ToolInventory(os: os, arch: arch, tools: tools)
    }

    /// The forwarder's relay: connects stdin/stdout to `host:port` inside the container with the first tool the image
    /// has (socat, bash's /dev/tcp, python3, nc, perl). Exit 7 = the port is not reachable; 8 = no relay tool.
    public static func relayScript(host: String, port: Int) -> [String] {
        let script = #"""
        h=$1; p=$2
        if command -v socat >/dev/null 2>&1; then
          case "$h" in *:*) exec socat - "TCP6:[$h]:$p";; *) exec socat - "TCP4:$h:$p";; esac
        fi
        if command -v bash >/dev/null 2>&1; then
          exec bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 7; ( cat <&3; kill -TERM -$$ 2>/dev/null ) & cat >&3; kill -TERM -$$ 2>/dev/null' relay "$h" "$p"
        fi
        if command -v python3 >/dev/null 2>&1; then
          exec python3 -c 'import socket,sys,threading
        try: s=socket.create_connection((sys.argv[1],int(sys.argv[2])))
        except OSError: sys.exit(7)
        def up():
            while True:
                d=sys.stdin.buffer.read1(65536)
                if not d: break
                s.sendall(d)
            s.shutdown(socket.SHUT_WR)
        threading.Thread(target=up,daemon=True).start()
        while True:
            d=s.recv(65536)
            if not d: break
            sys.stdout.buffer.write(d); sys.stdout.buffer.flush()' "$h" "$p"
        fi
        if command -v nc >/dev/null 2>&1; then exec nc "$h" "$p"; fi
        if command -v perl >/dev/null 2>&1; then
          exec perl -MIO::Socket::IP -e '$s=IO::Socket::IP->new(PeerHost=>$ARGV[0],PeerPort=>$ARGV[1]) or exit 7; if(fork){while(sysread(STDIN,$b,65536)){syswrite($s,$b)} shutdown($s,1); wait}else{while(sysread($s,$b,65536)){syswrite(STDOUT,$b)} exit}' "$h" "$p"
        fi
        echo "bellocode: the image has no socat, bash, python3, nc or perl to forward ports with" >&2
        exit 8
        """#
        return ["/bin/sh", "-c", script, "bellocode-relay", host, String(port)]
    }
}
