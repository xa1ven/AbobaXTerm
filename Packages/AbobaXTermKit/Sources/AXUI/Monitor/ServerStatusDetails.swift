import AXL10n
import AXSSH
import AXTerminal
import SwiftUI

// Popovers of the server status bar.

private struct DetailTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline) }
}

private struct UsageBar: View {
    var share: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(0, min(1, share)) * proxy.size.width)
            }
        }
        .frame(height: 5)
    }
}

private func usageTint(_ percent: Int) -> Color {
    percent >= 95 ? .red : percent >= 85 ? .orange : .accentColor
}

struct IdentityDetails: View {
    let tab: TerminalTab
    let monitor: ServerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailTitle(L("Connection"))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                if let user = monitor.user { row(L("User"), user) }
                if let host = monitor.host { row(L("Host name"), host) }
                if let session = tab.session { row(L("Address"), session.target) }
            }
            if monitor.status == .unavailable {
                Text(L("Statistics are not available for this server (they need Linux with /proc)."))
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

struct CPUDetails: View {
    var stats: ServerStats
    var history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                DetailTitle(L("CPU"))
                Spacer()
                Text(StatFormat.percent(stats.cpu)).monospacedDigit()
            }
            Sparkline(values: history).frame(height: 48)
            if stats.load.count == 3 {
                LabeledContent(L("Load average")) {
                    Text(stats.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")).monospacedDigit()
                }
            }
            if stats.cores.count > 1 {
                Text(LN(stats.cores.count, "%@ core", "%@ cores")).foregroundStyle(.secondary)
                let columns = stats.cores.count > 16 ? 4 : stats.cores.count > 4 ? 2 : 1
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 5) {
                        ForEach(Array(stats.cores.enumerated()), id: \.offset) { index, load in
                            HStack(spacing: 6) {
                                Text("\(index)").foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                                UsageBar(share: load)
                                Text(StatFormat.percent(load)).frame(width: 34, alignment: .trailing)
                            }
                            .font(.caption)
                            .monospacedDigit()
                        }
                    }
                }
                .frame(height: min(260, CGFloat((stats.cores.count + columns - 1) / columns) * 20))
            }
        }
        .frame(width: stats.cores.count > 16 ? 520 : stats.cores.count > 4 ? 340 : 240)
    }
}

struct MemoryDetails: View {
    var memory: ServerSample.Memory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailTitle(L("Memory"))
            UsageBar(share: memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                row(L("Total"), memory.total)
                row(L("Used"), memory.used)
                row(L("Available"), memory.available)
                row(L("Free"), memory.free)
                row(L("Buffers and cache"), memory.buffers + memory.cached)
            }
            if memory.swapTotal > 0 {
                Divider()
                Text(L("Swap")).foregroundStyle(.secondary)
                UsageBar(share: Double(memory.swapUsed) / Double(memory.swapTotal), tint: .orange)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    row(L("Total"), memory.swapTotal)
                    row(L("Used"), memory.swapUsed)
                }
            }
        }
        .frame(width: 240)
    }

    private func row(_ name: String, _ value: UInt64) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(StatFormat.bytes(value)).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }
}

struct NetworkDetails: View {
    var stats: ServerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailTitle(L("Network"))
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text(L("Interface")).gridColumnAlignment(.leading)
                    Label(L("Sent"), systemImage: "arrow.up")
                    Label(L("Received"), systemImage: "arrow.down")
                    Text(L("Total sent"))
                    Text(L("Total received"))
                }
                .foregroundStyle(.secondary)
                ForEach(stats.interfaces) { interface in
                    GridRow {
                        Text(interface.name)
                            .foregroundStyle(interface.isPhysical ? .primary : .secondary)
                        Text(StatFormat.rate(interface.sent))
                        Text(StatFormat.rate(interface.received))
                        Text(StatFormat.bytes(interface.totalSent))
                        Text(StatFormat.bytes(interface.totalReceived))
                    }
                    .monospacedDigit()
                }
            }
            .lineLimit(1)
            .fixedSize()
            Text(L("The status bar adds up physical interfaces; loopback, tunnels, bridges and container interfaces (dimmed) are left out."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 400, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct UptimeDetails: View {
    var stats: ServerStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailTitle(L("Uptime"))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text(L("Running for")).foregroundStyle(.secondary)
                    Text(StatFormat.uptime(stats.uptime))
                }
                GridRow {
                    Text(L("Started")).foregroundStyle(.secondary)
                    Text(Date().addingTimeInterval(-stats.uptime).formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }
}

struct DiskDetails: View {
    /// Every line of `df`, pseudo file systems included.
    var disks: [DiskUsage]

    var body: some View {
        let shown = Set(DiskFilter.visible(disks).map(\.mount))
        VStack(alignment: .leading, spacing: 8) {
            DetailTitle(L("File Systems"))
            ScrollView {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text(L("Mounted on")).fixedSize().gridColumnAlignment(.leading)
                        Text(L("Device")).gridColumnAlignment(.leading)
                        Text(L("Size")).fixedSize()
                        Text(L("Used")).fixedSize()
                        Text(L("Free")).fixedSize()
                        Text(L("Use")).fixedSize()
                        Color.clear.frame(width: 60, height: 1)
                    }
                    .foregroundStyle(.secondary)
                    ForEach(disks) { disk in
                        GridRow {
                            Text(disk.mount).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                            Text(disk.type.isEmpty ? disk.source : "\(disk.source) (\(disk.type))")
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 190, alignment: .leading)
                            Text(StatFormat.bytes(disk.total)).fixedSize()
                            Text(StatFormat.bytes(disk.used)).fixedSize()
                            Text(StatFormat.bytes(disk.available)).fixedSize()
                            Text("\(disk.percent)%").fixedSize()
                            UsageBar(share: Double(disk.percent) / 100, tint: usageTint(disk.percent)).frame(width: 60)
                        }
                        .monospacedDigit()
                        .foregroundStyle(shown.contains(disk.mount) ? .primary : .secondary)
                    }
                }
                .lineLimit(1)
                .frame(width: 600)
            }
            .frame(height: min(320, CGFloat(disks.count + 1) * 20))
            Text(L("The status bar lists partitions on real devices and a separate /tmp. Temporary, container and system file systems (dimmed) appear only here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 600, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
