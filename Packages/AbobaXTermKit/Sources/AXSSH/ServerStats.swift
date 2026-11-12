import Foundation

/// Raw counters read from a Linux server in one monitoring tick.
public struct ServerSample: Sendable, Equatable {
    public struct CPUTicks: Sendable, Equatable {
        public var total: UInt64
        /// idle + iowait
        public var idle: UInt64
    }

    public struct Memory: Sendable, Equatable {
        public var total: UInt64 = 0
        public var free: UInt64 = 0
        /// `MemAvailable`, or free + buffers + cached on kernels without it.
        public var available: UInt64 = 0
        public var buffers: UInt64 = 0
        public var cached: UInt64 = 0
        public var swapTotal: UInt64 = 0
        public var swapFree: UInt64 = 0

        public var used: UInt64 { total > available ? total - available : 0 }
        public var swapUsed: UInt64 { swapTotal > swapFree ? swapTotal - swapFree : 0 }
    }

    public struct Interface: Sendable, Equatable {
        public var name: String
        public var received: UInt64
        public var sent: UInt64
    }

    public var cpu: CPUTicks
    public var cores: [CPUTicks]
    public var memory: Memory
    public var interfaces: [Interface]
    /// Seconds since boot, from the server's own clock (also the time base for rates).
    public var uptime: TimeInterval
    public var load: [Double]
    /// nil in ticks that did not run `df`.
    public var disks: [DiskUsage]?
    /// Names of the interfaces backed by a device, sent together with `df`.
    public var physical: [String]?
}

/// One line of `df`.
public struct DiskUsage: Sendable, Equatable, Identifiable {
    public var source: String
    /// File system type; empty when the server's `df` cannot print it.
    public var type: String
    public var total: UInt64
    public var used: UInt64
    public var available: UInt64
    public var mount: String

    public var id: String { mount }

    /// Used share of the space an ordinary user can fill, rounded up like `df`.
    public var percent: Int {
        let usable = used + available
        guard usable > 0 else { return 0 }
        return Int((Double(used) * 100 / Double(usable)).rounded(.up))
    }

    public init(source: String, type: String, total: UInt64, used: UInt64, available: UInt64, mount: String) {
        self.source = source
        self.type = type
        self.total = total
        self.used = used
        self.available = available
        self.mount = mount
    }
}

/// What the status bar shows: rates and shares computed from two samples.
public struct ServerStats: Sendable, Equatable {
    public struct InterfaceRate: Sendable, Equatable, Identifiable {
        public var name: String
        /// Bytes per second.
        public var received: Double
        public var sent: Double
        public var totalReceived: UInt64
        public var totalSent: UInt64
        /// Counted in the status bar's totals.
        public var isPhysical = true
        public var id: String { name }
    }

    /// 0...1
    public var cpu: Double
    public var cores: [Double]
    public var memory: ServerSample.Memory
    /// Bytes per second over physical interfaces.
    public var received: Double
    public var sent: Double
    public var interfaces: [InterfaceRate]
    public var uptime: TimeInterval
    public var load: [Double]
    /// Every `df` line; the status bar shows `DiskFilter.visible(disks)`.
    public var disks: [DiskUsage]

    /// nil when the samples cannot be compared (server rebooted, clock did not advance).
    ///
    /// `physical` are the interfaces the server reports as backed by a device;
    /// when it reports none (containers, old kernels) names decide.
    public init?(previous: ServerSample, current: ServerSample, disks: [DiskUsage], physical: Set<String> = []) {
        let seconds = current.uptime - previous.uptime
        guard seconds > 0.05 else { return nil }

        func usage(_ a: ServerSample.CPUTicks, _ b: ServerSample.CPUTicks) -> Double {
            guard b.total > a.total, b.idle >= a.idle else { return 0 }
            let total = Double(b.total - a.total)
            return min(1, max(0, (total - Double(b.idle - a.idle)) / total))
        }
        cpu = usage(previous.cpu, current.cpu)
        cores = previous.cores.count == current.cores.count
            ? zip(previous.cores, current.cores).map(usage) : []
        memory = current.memory
        uptime = current.uptime
        load = current.load
        self.disks = disks

        let before = Dictionary(previous.interfaces.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        interfaces = current.interfaces.map { now in
            var rate = InterfaceRate(name: now.name, received: 0, sent: 0,
                                     totalReceived: now.received, totalSent: now.sent)
            rate.isPhysical = now.name != "lo"
                && (physical.isEmpty ? !ServerStats.isVirtualInterface(now.name) : physical.contains(now.name))
            // A counter that went down was reset (interface re-created): no rate this tick.
            if let old = before[now.name], now.received >= old.received, now.sent >= old.sent {
                rate.received = Double(now.received - old.received) / seconds
                rate.sent = Double(now.sent - old.sent) / seconds
            }
            return rate
        }
        let counted = interfaces.filter(\.isPhysical)
        received = counted.reduce(0) { $0 + $1.received }
        sent = counted.reduce(0) { $0 + $1.sent }
    }

    /// Loopback, tunnels, container and VM bridges, by name: their traffic is
    /// local or is counted once more on the real interface.
    public static func isVirtualInterface(_ name: String) -> Bool {
        name == "lo" || ["veth", "docker", "br-", "virbr", "vnet", "cni", "flannel", "cali", "kube", "lxc", "tap", "tun", "wg", "tailscale", "zt"]
            .contains { name.hasPrefix($0) }
    }
}

/// Picks the `df` lines worth a place in the status bar.
public enum DiskFilter {
    private static let pseudoTypes: Set<String> = [
        "devtmpfs", "tmpfs", "overlay", "squashfs", "efivarfs", "proc", "sysfs", "cgroup", "cgroup2",
        "iso9660", "udf", "ramfs", "devpts", "autofs", "fuse.portal", "fuse.gvfsd-fuse", "fuse.lxcfs", "nsfs",
    ]
    private static let hiddenPrefixes = [
        "/dev", "/run", "/sys", "/proc", "/snap", "/var/snap",
        "/var/lib/docker", "/var/lib/containers", "/var/lib/kubelet", "/var/lib/containerd",
        // Files a container runtime mounts over the image's own.
        "/etc/resolv.conf", "/etc/hostname", "/etc/hosts",
    ]

    /// Real partitions plus a separate `/tmp`, in `df` order; a device mounted
    /// in several places (bind mounts, btrfs subvolumes) is listed once, by
    /// its shortest mount point.
    public static func visible(_ disks: [DiskUsage]) -> [DiskUsage] {
        var result: [DiskUsage] = []
        for disk in disks where disk.total > 0 {
            let mount = disk.mount
            if mount != "/" {
                if hiddenPrefixes.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) { continue }
                if mount != "/tmp" {
                    if pseudoTypes.contains(disk.type) { continue }
                    if disk.type.isEmpty, !disk.source.hasPrefix("/dev/") { continue }
                }
            }
            if let index = result.firstIndex(where: { $0.source == disk.source && $0.total == disk.total && disk.source.contains("/") }) {
                if mount.count < result[index].mount.count { result[index] = disk }
                continue
            }
            result.append(disk)
        }
        return result
    }
}

/// Number formats of the status bar.
public enum StatFormat {
    /// Binary units labelled the way `df -h` and `free -h` do: "301 MB", "45.9 GB", "2.9 TB".
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var number = Double(value)
        var unit = 0
        while number >= 1000, unit < units.count - 1 {
            number /= 1024
            unit += 1
        }
        return (unit == 0 || number >= 100 ? String(format: "%.0f", number)
                : number >= 10 ? String(format: "%.1f", number) : String(format: "%.2f", number)) + " " + units[unit]
    }

    /// Network speed in bits per second: "0 kb/s", "850 kb/s", "12.4 Mb/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let bits = max(0, bytesPerSecond) * 8
        if bits < 999_500 { return String(format: "%.0f kb/s", bits / 1000) }
        if bits < 999_500_000 { return String(format: bits < 99_950_000 ? "%.1f Mb/s" : "%.0f Mb/s", bits / 1_000_000) }
        return String(format: "%.2f Gb/s", bits / 1_000_000_000)
    }

    /// "45 s", "31 min", "5 h 12 min", "23 d 4 h".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (days, hours, minutes) = (total / 86400, total % 86400 / 3600, total % 3600 / 60)
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return minutes > 0 ? "\(minutes) min" : "\(total) s"
    }

    public static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}
