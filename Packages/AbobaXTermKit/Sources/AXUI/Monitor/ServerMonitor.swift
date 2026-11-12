import AXModels
import AXSSH
import AXTerminal
import Foundation
import Observation

/// Live server statistics of one SSH tab, read over its master connection.
@MainActor
@Observable
final class ServerMonitor {
    enum Status: Equatable {
        /// Not running, or waiting for the connection and the first numbers.
        case idle
        case live
        /// The server is not Linux, or the channel could not be opened.
        case unavailable
    }

    static let historyLength = 60

    private(set) var status: Status = .idle
    private(set) var stats: ServerStats?
    /// CPU load (0...1) of the last ticks, oldest first.
    private(set) var cpuHistory: [Double] = []
    private(set) var user: String?
    private(set) var host: String?

    @ObservationIgnored private weak var tab: TerminalTab?
    @ObservationIgnored private var previous: ServerSample?
    @ObservationIgnored private var disks: [DiskUsage] = []
    @ObservationIgnored private var physical: Set<String> = []

    init(tab: TerminalTab) {
        self.tab = tab
    }

    /// Reads statistics until the task is cancelled (the status bar went
    /// away) or the connection ends. Never prompts and gives up after a few
    /// failed attempts instead of retrying forever.
    func run(builder: SSHCommandBuilder, interval: Int) async {
        guard let session = tab?.session else { return }
        var failures = 0
        while !Task.isCancelled, failures < 3 {
            // The terminal's ssh has to bring the master up first.
            var attempt = 0
            while !(await ControlMasterManager.isMasterRunning(session, builder: builder)) {
                guard !Task.isCancelled, tab?.state.isActive == true else {
                    reset()
                    return
                }
                attempt += 1
                try? await Task.sleep(for: .milliseconds(attempt < 40 ? 250 : 1000))
            }
            guard !Task.isCancelled else { return }

            previous = nil
            var gotSample = false
            do {
                var parser = ServerMonitorParser()
                let command = ServerMonitorScript.command(interval: interval)
                for await line in try RemoteStream.lines(command, session: session, builder: builder) {
                    switch parser.feed(line) {
                    case .identity(let user, let host):
                        self.user = user
                        self.host = host
                    case .sample(let sample):
                        gotSample = true
                        apply(sample)
                    case .unsupported:
                        reset(.unavailable)
                        return
                    case nil:
                        break
                    }
                }
            } catch {
                reset(.unavailable)
                return
            }
            guard !Task.isCancelled else { return }
            // The channel closed: with the connection, or by itself.
            guard tab?.state == .running else {
                reset()
                return
            }
            failures = gotSample ? 1 : failures + 1
            try? await Task.sleep(for: .seconds(2))
        }
        if !Task.isCancelled { reset(.unavailable) }
    }

    /// Forgets the numbers of a connection that has ended.
    func clear() {
        reset()
    }

    private func apply(_ sample: ServerSample) {
        if let fresh = sample.disks { disks = fresh }
        if let fresh = sample.physical { physical = Set(fresh) }
        defer { previous = sample }
        guard let previous, let stats = ServerStats(previous: previous, current: sample, disks: disks, physical: physical) else { return }
        self.stats = stats
        status = .live
        cpuHistory.append(stats.cpu)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
    }

    private func reset(_ status: Status = .idle) {
        self.status = status
        stats = nil
        previous = nil
        cpuHistory = []
    }
}
