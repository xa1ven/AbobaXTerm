@testable import AXSSH
import Foundation
import Testing

@Suite struct ServerMonitorTests {
    static let block1 = """
    @@abx who
    root
    hwdev60
    @@abx cpu
    cpu  1000 0 500 8000 500 0 0 0 0 0
    cpu0 500 0 250 4000 250 0 0 0 0 0
    cpu1 500 0 250 4000 250 0 0 0 0 0
    @@abx mem
    MemTotal:        1000000 kB
    MemFree:          200000 kB
    MemAvailable:     700000 kB
    Buffers:           50000 kB
    Cached:           400000 kB
    SwapTotal:        100000 kB
    SwapFree:          75000 kB
    @@abx net
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 5000 10 0 0 0 0 0 0 5000 10 0 0 0 0 0 0
      eth0: 100000 10 0 0 0 0 0 0 20000 10 0 0 0 0 0 0
    docker0:1000 1 0 0 0 0 0 0 1000 1 0 0 0 0 0 0
    @@abx up
    100.00 350.12
    0.50 0.25 0.10 1/200 4242
    @@abx df
    Filesystem     Type     1024-blocks      Used Available Capacity Mounted on
    devtmpfs       devtmpfs        4096         0      4096       0% /dev
    tmpfs          tmpfs      528482304        16 528482288       1% /dev/shm
    /dev/sda4      xfs         72351744  47185920  22020096      69% /
    /dev/sda2      xfs           997376    261120    667648      29% /boot
    tmpfs          tmpfs      528482304         0 528482304       0% /tmp
    /dev/nvme0n1p1 xfs       3113851289 873453158 2147483648      30% /home
    /dev/sda1      vfat          613376      7987    605389       2% /boot/efi
    overlay        overlay   3113851289 873453158 2147483648      30% /home/docker/overlay2/abc/merged
    /dev/nvme0n1p1 xfs       3113851289 873453158 2147483648      30% /home/docker
    /dev/sdb1      ext4         1000000    500000    400000      56% /mnt/my data
    @@abx end
    """

    static let block2 = """
    @@abx cpu
    cpu  1150 0 550 8200 500 0 0 0 0 0
    cpu0 650 0 300 4050 250 0 0 0 0 0
    cpu1 500 0 250 4150 250 0 0 0 0 0
    @@abx mem
    MemTotal:        1000000 kB
    MemFree:          100000 kB
    Buffers:           50000 kB
    Cached:           400000 kB
    @@abx net
        lo: 9000 10 0 0 0 0 0 0 9000 10 0 0 0 0 0 0
      eth0: 300000 10 0 0 0 0 0 0 60000 10 0 0 0 0 0 0
    docker0:9000 1 0 0 0 0 0 0 9000 1 0 0 0 0 0 0
    @@abx up
    102.00 352.12
    0.60 0.25 0.10 1/200 4243
    @@abx end
    """

    private func events(_ text: String, parser: inout ServerMonitorParser) -> [ServerMonitorParser.Event] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { parser.feed(String($0)) }
    }

    @Test func parsesBlocksAndComputesRates() throws {
        var parser = ServerMonitorParser()
        let first = events(Self.block1, parser: &parser)
        #expect(first.first == .identity(user: "root", host: "hwdev60"))
        guard case .sample(let a) = try #require(first.last) else { Issue.record("no sample"); return }
        #expect(a.cores.count == 2)
        #expect(a.memory.used == 300_000 * 1024)
        #expect(a.memory.swapUsed == 25000 * 1024)
        #expect(a.interfaces.map(\.name) == ["lo", "eth0", "docker0"])
        #expect(a.load == [0.5, 0.25, 0.1])
        let disks = try #require(a.disks)
        #expect(disks.count == 10)
        #expect(disks.last?.mount == "/mnt/my data")

        let second = events(Self.block2, parser: &parser)
        guard case .sample(let b) = try #require(second.last), second.count == 1 else { Issue.record("no sample"); return }
        #expect(b.disks == nil)
        // No MemAvailable: free + buffers + cached.
        #expect(b.memory.available == 550_000 * 1024)

        let stats = try #require(ServerStats(previous: a, current: b, disks: disks))
        // 400 ticks passed, 200 of them idle.
        #expect(abs(stats.cpu - 0.5) < 0.001)
        #expect(abs(stats.cores[0] - 0.8) < 0.001)
        #expect(stats.cores[1] == 0)
        // Only eth0 counts: 200000 bytes in 2 s.
        #expect(stats.received == 100_000)
        #expect(stats.sent == 20000)
        #expect(stats.interfaces.count == 3)
        #expect(ServerStats(previous: b, current: a, disks: []) == nil)
    }

    @Test func statusBarShowsRealPartitionsOnce() throws {
        var parser = ServerMonitorParser()
        guard case .sample(let a) = try #require(events(Self.block1, parser: &parser).last) else { return }
        let visible = DiskFilter.visible(try #require(a.disks))
        #expect(visible.map(\.mount) == ["/", "/boot", "/tmp", "/home", "/boot/efi", "/mnt/my data"])
        #expect(visible.map(\.percent) == [69, 29, 0, 29, 2, 56])
    }

    @Test func diskListWithoutTypeColumn() {
        let disks = ServerMonitorParser.disks([
            "Filesystem           1024-blocks    Used Available Capacity Mounted on",
            "/dev/root               10000      4000      6000  40% /",
            "tmpfs                    1000         0      1000   0% /tmp",
            "tmpfs                    1000         0      1000   0% /var/volatile",
            "garbage line",
        ])
        #expect(disks.count == 3)
        #expect(DiskFilter.visible(disks).map(\.mount) == ["/", "/tmp"])
    }

    @Test func serverSaysWhichInterfacesArePhysical() throws {
        func block(_ uptime: Int, _ bytes: Int, phy: String) -> String {
            """
            @@abx cpu
            cpu  \(uptime) 0 0 \(uptime)
            @@abx net
                lo: \(bytes) 0 0 0 0 0 0 0 \(bytes) 0 0 0 0 0 0 0
              ens3: \(bytes) 0 0 0 0 0 0 0 \(bytes) 0 0 0 0 0 0 0
              amn0: \(bytes) 0 0 0 0 0 0 0 \(bytes) 0 0 0 0 0 0 0
              eth7: \(bytes) 0 0 0 0 0 0 0 \(bytes) 0 0 0 0 0 0 0
            @@abx up
            \(uptime).00 1.00
            0 0 0
            \(phy)@@abx end
            """
        }
        var parser = ServerMonitorParser()
        guard case .sample(let a) = try #require(events(block(10, 0, phy: "@@abx phy\nens3\nlo\n"), parser: &parser).last),
              case .sample(let b) = try #require(events(block(12, 2000, phy: ""), parser: &parser).last)
        else { Issue.record("no sample"); return }
        #expect(a.physical == ["ens3", "lo"])
        #expect(b.physical == nil)

        // The VPN tunnel carries the same bytes as ens3 and must not be added again.
        let told = try #require(ServerStats(previous: a, current: b, disks: [], physical: Set(a.physical ?? [])))
        #expect(told.received == 1000)
        #expect(told.interfaces.filter(\.isPhysical).map(\.name) == ["ens3"])
        // A server that reports nothing (a container): names decide.
        let guessed = try #require(ServerStats(previous: a, current: b, disks: []))
        #expect(guessed.interfaces.filter(\.isPhysical).map(\.name) == ["ens3", "amn0", "eth7"])
    }

    @Test func containerBindMountsAreNotDisks() {
        let disks = ServerMonitorParser.disks([
            "Filesystem           Type       1024-blocks    Used Available Capacity Mounted on",
            "overlay              overlay       10234012 4045944   5647564  42% /",
            "/dev/vda2            ext4          10234012 4045944   5647564  42% /etc/resolv.conf",
            "/dev/vda2            ext4          10234012 4045944   5647564  42% /etc/hosts",
            "/dev/vdb1            ext4          50000000 1000000  49000000   3% /data",
        ])
        #expect(DiskFilter.visible(disks).map(\.mount) == ["/", "/data"])
    }

    @Test func damagedOutputIsIgnored() {
        var parser = ServerMonitorParser()
        #expect(events("noise\n@@abx cpu\ncpu 1 2\n@@abx up\n\n@@abx end\n@@abx end", parser: &parser).isEmpty)
        #expect(events("@@abx cpu\ncpu  1 2 3 4\n@@abx up\n5.5 1\n@@abx end", parser: &parser).count == 1)
        #expect(events("@@abx unsupported", parser: &parser) == [.unsupported])
    }

    @Test func formats() {
        #expect(StatFormat.bytes(0) == "0 B")
        #expect(StatFormat.bytes(322_122_547) == "307 MB")
        #expect(StatFormat.bytes(1_009_317_314) == "963 MB")
        #expect(StatFormat.bytes(49_263_000_000) == "45.9 GB")
        #expect(StatFormat.bytes(1023 * 1024 * 1024) == "1.00 GB")
        #expect(StatFormat.rate(0) == "0 kb/s")
        #expect(StatFormat.rate(1250) == "10 kb/s")
        #expect(StatFormat.rate(1_550_000) == "12.4 Mb/s")
        #expect(StatFormat.uptime(31 * 60 + 5) == "31 min")
        #expect(StatFormat.uptime(23 * 86400 + 4 * 3600 + 60) == "23 d 4 h")
        #expect(StatFormat.uptime(42) == "42 s")
    }

    /// The script itself, through /bin/sh: this Mac has no /proc.
    @Test func scriptReportsUnsupportedWithoutProc() throws {
        let command = ServerMonitorScript.command(interval: 2)
        if let path = ProcessInfo.processInfo.environment["ABX_DUMP_MONITOR_COMMAND"] {
            try command.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(!command.dropFirst("exec sh -c '".count).dropLast().contains("'"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var parser = ServerMonitorParser()
        #expect(events(output, parser: &parser) == [.unsupported])
    }
}
