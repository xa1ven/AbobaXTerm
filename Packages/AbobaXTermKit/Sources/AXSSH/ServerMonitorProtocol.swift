import Foundation

/// The remote side of server monitoring: a shell loop that prints kernel
/// counters, and the parser for what it prints. Nothing is installed or
/// written on the server.
public enum ServerMonitorScript {
    static let marker = "@@abx "

    /// Prints a block of sections every `interval` seconds (the second block
    /// follows the first after one second, so rates appear quickly); `df`
    /// runs in every `diskEvery`-th block. Ends by itself once the channel
    /// is closed. Servers without /proc answer "unsupported" and exit.
    public static func command(interval: Int, diskEvery: Int = 5) -> String {
        let interval = max(1, interval), diskEvery = max(1, diskEvery)
        // No single quotes and no "!" inside: the user's login shell (which
        // may be csh or fish) only has to pass one quoted word to sh.
        let script = [
            "export LC_ALL=C",
            "[ -r /proc/stat ] && [ -r /proc/meminfo ] || { echo @@abx unsupported; exit 0; }",
            "echo @@abx who; id -un; hostname 2>/dev/null || cat /proc/sys/kernel/hostname",
            // -l: local file systems only, a dead NFS mount must not hang the loop.
            // busybox has -T but not -l.
            "if df -PTl / >/dev/null 2>&1; then d=\"df -PTl\"; elif df -PT / >/dev/null 2>&1; then d=\"df -PT\"; else d=\"df -P\"; fi",
            "n=0",
            "while :; do echo @@abx cpu; grep -m 513 ^cpu /proc/stat"
                + "; echo @@abx mem; grep -E \"^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):\" /proc/meminfo"
                + "; echo @@abx net; cat /proc/net/dev"
                + "; echo @@abx up; cat /proc/uptime /proc/loadavg"
                + "; if [ $((n % \(diskEvery))) -eq 0 ]; then echo @@abx df; $d 2>/dev/null"
                // Interfaces backed by a device: tunnels, bridges and container pairs have none.
                + "; echo @@abx phy; for i in /sys/class/net/*; do [ -e $i/device ] && echo ${i##*/}; done; fi"
                + "; n=$((n + 1))"
                // Where SIGPIPE is ignored a closed channel only fails the write.
                + "; echo @@abx end || exit"
                + "; if [ $n -eq 1 ]; then sleep 1; else sleep \(interval); fi; done",
        ].joined(separator: "; ")
        return "exec sh -c " + ShellWords.quote(script)
    }
}

/// Turns the script's output, fed line by line, into events.
public struct ServerMonitorParser: Sendable {
    public enum Event: Sendable, Equatable {
        case identity(user: String, host: String)
        case sample(ServerSample)
        case unsupported
    }

    private var section = ""
    private var lines: [String: [String]] = [:]

    public init() {}

    public mutating func feed(_ line: String) -> Event? {
        guard line.hasPrefix(ServerMonitorScript.marker) else {
            if !section.isEmpty { lines[section, default: []].append(line) }
            return nil
        }
        let name = String(line.dropFirst(ServerMonitorScript.marker.count)).trimmingCharacters(in: .whitespaces)
        switch name {
        case "unsupported":
            return .unsupported
        case "end":
            defer {
                section = ""
                lines = [:]
            }
            return Self.sample(from: lines).map(Event.sample)
        default:
            // The identity section ends where the first block starts.
            var event: Event?
            if section == "who", let who = lines["who"], who.count >= 2 {
                event = .identity(user: who[0], host: who[1])
                lines["who"] = nil
            }
            section = name
            lines[name] = []
            return event
        }
    }

    static func sample(from lines: [String: [String]]) -> ServerSample? {
        let cpus = (lines["cpu"] ?? []).compactMap(Self.cpuTicks)
        guard let all = cpus.first(where: { $0.name == "cpu" }),
              let up = lines["up"], let uptime = up.first?.split(separator: " ").first.flatMap({ Double($0) })
        else { return nil }
        let load = up.count > 1 ? up[1].split(separator: " ").prefix(3).compactMap { Double($0) } : []
        return ServerSample(
            cpu: all.ticks,
            cores: cpus.filter { $0.name != "cpu" }.map(\.ticks),
            memory: memory(lines["mem"] ?? []),
            interfaces: (lines["net"] ?? []).compactMap(interface),
            uptime: uptime,
            load: load,
            disks: lines["df"].map(disks),
            physical: lines["phy"].map { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
    }

    /// "cpu0 4705 150 1120 16250 520 0 12 0 0 0": user nice system idle iowait irq softirq steal …
    static func cpuTicks(_ line: String) -> (name: String, ticks: ServerSample.CPUTicks)? {
        let fields = line.split(separator: " ")
        guard let name = fields.first, name.hasPrefix("cpu") else { return nil }
        let values = fields.dropFirst().prefix(8).map { UInt64($0) ?? 0 }
        guard values.count >= 4 else { return nil }
        let idle = values[3] + (values.count > 4 ? values[4] : 0)
        return (String(name), .init(total: values.reduce(0, +), idle: idle))
    }

    static func memory(_ lines: [String]) -> ServerSample.Memory {
        var values: [String: UInt64] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let kb = parts[1].split(separator: " ").first.flatMap({ UInt64($0) }) else { continue }
            values[String(parts[0])] = kb * 1024
        }
        var memory = ServerSample.Memory()
        memory.total = values["MemTotal"] ?? 0
        memory.free = values["MemFree"] ?? 0
        memory.buffers = values["Buffers"] ?? 0
        memory.cached = values["Cached"] ?? 0
        memory.available = values["MemAvailable"] ?? min(memory.total, memory.free + memory.buffers + memory.cached)
        memory.swapTotal = values["SwapTotal"] ?? 0
        memory.swapFree = values["SwapFree"] ?? 0
        return memory
    }

    /// "  eth0: 123 4 0 0 0 0 0 0 456 7 0 0 0 0 0 0": received bytes first, sent bytes ninth.
    static func interface(_ line: String) -> ServerSample.Interface? {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let fields = parts[1].split(separator: " ")
        guard fields.count >= 9, let received = UInt64(fields[0]), let sent = UInt64(fields[8]) else { return nil }
        return .init(name: parts[0].trimmingCharacters(in: .whitespaces), received: received, sent: sent)
    }

    /// `df -P` output, with or without the type column of `-T`; sizes are 1K blocks.
    static func disks(_ lines: [String]) -> [DiskUsage] {
        guard let header = lines.first else { return [] }
        let hasType = header.split(separator: " ").dropFirst().first == "Type"
        let first = hasType ? 2 : 1
        return lines.dropFirst().compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= first + 5,
                  let total = UInt64(fields[first]), let used = UInt64(fields[first + 1]),
                  let available = UInt64(fields[first + 2]), fields[first + 3].hasSuffix("%") else { return nil }
            return DiskUsage(source: String(fields[0]), type: hasType ? String(fields[1]) : "",
                             total: total * 1024, used: used * 1024, available: available * 1024,
                             mount: fields[(first + 4)...].joined(separator: " "))
        }
    }
}
