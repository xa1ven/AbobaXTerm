import AXL10n
import AXSSH
import AXTerminal
import SwiftUI

/// Status bar under an SSH terminal: who and where, CPU, memory, network,
/// uptime and disks. Each item opens its details on click.
struct ServerStatusBar: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab
    let monitor: ServerMonitor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
            StatusItem(icon: "person.crop.circle", text: identity, help: L("User and host")) { IdentityDetails(tab: tab, monitor: monitor) }
            if let stats = monitor.stats {
                separator
                StatusItem(icon: "cpu", text: StatFormat.percent(stats.cpu), minTextWidth: 32, help: L("CPU load")) {
                    CPUDetails(stats: stats, history: monitor.cpuHistory)
                } accessory: {
                    Sparkline(values: monitor.cpuHistory)
                        .frame(width: 54, height: 13)
                }
                separator
                StatusItem(icon: "memorychip",
                           text: "\(StatFormat.bytes(stats.memory.used)) / \(StatFormat.bytes(stats.memory.total))",
                           help: L("Memory: used / total")) { MemoryDetails(memory: stats.memory) }
                separator
                StatusItem(icon: "arrow.up", text: StatFormat.rate(stats.sent), minTextWidth: 54, help: L("Network: sent")) {
                    NetworkDetails(stats: stats)
                }
                StatusItem(icon: "arrow.down", text: StatFormat.rate(stats.received), minTextWidth: 54, help: L("Network: received")) {
                    NetworkDetails(stats: stats)
                }
                separator
                StatusItem(icon: "clock", text: StatFormat.uptime(stats.uptime), help: L("Uptime")) { UptimeDetails(stats: stats) }
                let disks = DiskFilter.visible(stats.disks)
                if !disks.isEmpty {
                    separator
                    ForEach(Array(disks.enumerated()), id: \.element.id) { index, disk in
                        StatusItem(icon: index == 0 ? "internaldrive" : nil,
                                   text: "\(disk.mount): \(disk.percent)%",
                                   tint: disk.percent >= 95 ? .red : disk.percent >= 85 ? .orange : nil,
                                   help: L("Disk usage")) { DiskDetails(disks: stats.disks) }
                    }
                }
            } else if monitor.status == .idle, tab.state.isActive {
                separator
                ProgressView().controlSize(.mini).padding(.horizontal, 8)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 24)
        .background(.bar)
        .task(id: TaskKey(running: tab.state == .running, interval: model.monitorInterval)) {
            // A closed connection must not keep showing its last numbers.
            guard tab.state == .running else { monitor.clear(); return }
            await monitor.run(builder: model.sshBuilder, interval: model.monitorInterval)
        }
    }

    private struct TaskKey: Equatable {
        var running: Bool
        var interval: Int
    }

    private var identity: String {
        let user = monitor.user ?? tab.session?.user.flatMap { $0.isEmpty ? nil : $0 }
        let host = monitor.host ?? tab.session?.host ?? ""
        return user.map { "\($0)@\(host)" } ?? host
    }

    private var separator: some View {
        Divider().frame(height: 12).padding(.horizontal, 2)
    }
}

/// One clickable cell of the bar with a popover.
private struct StatusItem<Details: View, Accessory: View>: View {
    var icon: String?
    var text: String
    var minTextWidth: CGFloat?
    var tint: Color?
    var help: String
    @ViewBuilder var details: () -> Details
    @ViewBuilder var accessory: () -> Accessory
    @State private var isOpen = false
    @State private var isHovered = false

    init(icon: String?, text: String, minTextWidth: CGFloat? = nil, tint: Color? = nil, help: String,
         @ViewBuilder details: @escaping () -> Details, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.icon = icon
        self.text = text
        self.minTextWidth = minTextWidth
        self.tint = tint
        self.help = help
        self.details = details
        self.accessory = accessory
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
                Text(text)
                    .foregroundStyle(tint ?? .primary)
                    .frame(minWidth: minTextWidth, alignment: .leading)
                accessory()
            }
            .padding(.horizontal, 7)
            .frame(maxHeight: .infinity)
            .background(isHovered || isOpen ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
        .help(help)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            details().padding(14)
        }
    }
}

extension StatusItem where Accessory == EmptyView {
    init(icon: String?, text: String, minTextWidth: CGFloat? = nil, tint: Color? = nil, help: String,
         @ViewBuilder details: @escaping () -> Details) {
        self.init(icon: icon, text: text, minTextWidth: minTextWidth, tint: tint, help: help, details: details) { EmptyView() }
    }
}

/// Filled line graph of values in 0...1; newest value at the right edge.
struct Sparkline: View {
    var values: [Double]
    var capacity = ServerMonitor.historyLength

    var body: some View {
        Canvas { context, size in
            let frame = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2.5)
            context.fill(frame, with: .color(.primary.opacity(0.08)))
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(index),
                                    y: size.height - 0.5 - (size.height - 1) * min(1, max(0, value)))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.clip(to: frame)
            context.fill(area, with: .color(.accentColor.opacity(0.3)))
            context.stroke(line, with: .color(.accentColor), lineWidth: 1)
        }
    }
}
