import AXL10n
import AXSFTP
import Foundation
import Observation
import Synchronization

/// One upload or download shown in the file panel.
@MainActor
@Observable
public final class TransferItem: Identifiable {
    public enum Direction: Sendable { case upload, download }
    public enum State: Equatable {
        case queued, running, finished, cancelled
        case failed(String)

        var isActive: Bool { self == .queued || self == .running }
    }

    public let id = UUID()
    public let name: String
    public let direction: Direction
    public internal(set) var totalBytes: UInt64?
    public internal(set) var doneBytes: UInt64 = 0
    public internal(set) var state: State = .queued

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored let work: @Sendable (SFTPClient, @escaping SFTPProgress) async throws -> Void
    /// Size computed in the background before the transfer starts (folders).
    @ObservationIgnored let measure: (@Sendable (SFTPClient) async throws -> UInt64)?
    @ObservationIgnored let completion: (@MainActor (Error?) -> Void)?

    init(name: String, direction: Direction, totalBytes: UInt64?,
         measure: (@Sendable (SFTPClient) async throws -> UInt64)? = nil,
         work: @escaping @Sendable (SFTPClient, @escaping SFTPProgress) async throws -> Void,
         completion: (@MainActor (Error?) -> Void)? = nil) {
        self.name = name
        self.direction = direction
        self.totalBytes = totalBytes
        self.measure = measure
        self.work = work
        self.completion = completion
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return state == .finished ? 1 : nil }
        return min(1, Double(doneBytes) / Double(totalBytes))
    }

    public func cancel() {
        if state == .queued {
            state = .cancelled
            completion?(CancellationError())
        }
        task?.cancel()
    }
}

/// Runs transfers in the background, two at a time, over one SFTP client.
@MainActor
@Observable
public final class TransferQueue {
    public private(set) var items: [TransferItem] = []
    @ObservationIgnored var clientProvider: () -> SFTPClient? = { nil }
    @ObservationIgnored private let maxConcurrent = 2

    public var hasActive: Bool { items.contains { $0.state.isActive } }

    func enqueue(_ item: TransferItem) {
        items.append(item)
        pump()
    }

    public func remove(_ item: TransferItem) {
        guard !item.state.isActive else { return }
        items.removeAll { $0.id == item.id }
    }

    public func clearFinished() {
        items.removeAll { !$0.state.isActive }
    }

    public func cancelAll() {
        for item in items where item.state.isActive { item.cancel() }
    }

    private func pump() {
        let running = items.filter { $0.state == .running }.count
        guard running < maxConcurrent, let next = items.first(where: { $0.state == .queued }) else { return }
        guard let client = clientProvider() else {
            for item in items where item.state == .queued {
                item.state = .failed(L("Not connected"))
                item.completion?(SFTPError(status: .noConnection, message: L("Not connected")))
            }
            return
        }
        start(next, client: client)
        pump()
    }

    private func start(_ item: TransferItem, client: SFTPClient) {
        item.state = .running
        let reporter = ProgressReporter { [weak item] bytes in item?.doneBytes = bytes }
        item.task = Task { [weak self] in
            var failure: Error?
            do {
                if let measure = item.measure {
                    item.totalBytes = try await measure(client)
                }
                try await item.work(client) { reporter.report($0) }
                reporter.flush()
                item.state = .finished
                item.doneBytes = max(item.doneBytes, item.totalBytes ?? 0)
            } catch is CancellationError {
                item.state = .cancelled
                failure = CancellationError()
            } catch {
                item.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                failure = error
            }
            item.completion?(failure)
            self?.finished(item)
        }
    }

    private func finished(_ item: TransferItem) {
        pump()
        // Successful items disappear after a moment; failures stay visible.
        guard item.state == .finished || item.state == .cancelled else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.remove(item)
        }
    }
}

/// Throttles progress callbacks from the transfer thread to ~10 UI updates/s.
final class ProgressReporter: Sendable {
    private struct State { var latest: UInt64 = 0; var lastPost = ContinuousClock.now - .seconds(1); var posted = true }
    private let state = Mutex(State())
    private let update: @MainActor (UInt64) -> Void

    init(update: @escaping @MainActor (UInt64) -> Void) {
        self.update = update
    }

    func report(_ bytes: UInt64) {
        let shouldPost = state.withLock { s -> Bool in
            s.latest = bytes
            let now = ContinuousClock.now
            guard now - s.lastPost >= .milliseconds(100) else {
                s.posted = false
                return false
            }
            s.lastPost = now
            s.posted = true
            return true
        }
        if shouldPost { post() }
    }

    func flush() { post() }

    private func post() {
        let update = update
        Task { @MainActor [self] in
            update(self.state.withLock { $0.latest })
        }
    }
}
