import Foundation

public struct TransferSnapshot: Sendable {
    public let sentBytes: Int64
    public let bytesPerSecond: Double?
    public let remainingSeconds: Double?
}

/// URLSession calls arrive off the main thread. Keep byte accounting synchronous
/// and bounded; the UI samples it once a second rather than queuing a task per callback.
public final class TransferStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let started: TimeInterval
    private var sent: Int64 = 0
    private var confirmed: Int64 = 0
    private var requests: [UUID: Int64] = [:]
    private var samples: [(time: TimeInterval, bytes: Int64)]
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock; started = clock(); samples = [(started, 0)]
    }
    public func beginRequest() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); requests[id] = 0; return id
    }
    public func sent(_ total: Int64, request: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let previous = requests[request], total > previous else { return }
        sent += total - previous; requests[request] = total
    }
    public func endRequest(_ request: UUID) {
        lock.lock(); defer { lock.unlock() }
        requests.removeValue(forKey: request)
    }
    public func confirm(_ newBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        confirmed += max(0, newBytes)
    }
    public func snapshot(remainingBytes: Int64) -> TransferSnapshot {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if now - samples.last!.time >= 0.5 { samples.append((now, sent)) }
        // Keep the sample immediately before the ten-second window as an anchor.
        while samples.count > 2 && samples[1].time <= now - 10 { samples.removeFirst() }
        let duration = now - samples[0].time
        let rate = sent > 0 && duration >= 0.5 ? Double(sent - samples[0].bytes) / duration : nil
        let elapsed = now - started
        // ETA uses newly acknowledged bytes, never old resume offsets or skipped files.
        // Including integrity checks and retry waits in elapsed time makes it conservative.
        let eta = remainingBytes > 0 && elapsed >= 2 && confirmed > 0 && (rate ?? 0) > 0
            ? Double(remainingBytes) / (Double(confirmed) / elapsed) : nil
        return TransferSnapshot(sentBytes: sent, bytesPerSecond: rate, remainingSeconds: eta)
    }
}

/// Adds only a bounded number of tasks; a fatal error cancels and drains the group.
public enum BoundedWork {
    public static func run<Value: Sendable>(_ values: [Value], limit: Int,
        operation: @escaping @Sendable (Value) async throws -> Void) async throws {
        guard [1, 2, 4].contains(limit) else { throw ArchiveError("Choose 1, 2, or 4 simultaneous uploads.") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() throws {
                try Task.checkCancellation()
                let value = values[next]; next += 1
                group.addTask { try Task.checkCancellation(); try await operation(value) }
            }
            do {
                for _ in 0..<min(limit, values.count) { try enqueue() }
                while try await group.next() != nil {
                    if next < values.count { try enqueue() }
                }
                try Task.checkCancellation()
            } catch { group.cancelAll(); throw error }
        }
    }
}

public protocol ArchiveStorage: Sendable {
    func exists(_ item: AudioItem) async throws -> Bool
    func upload(_ item: AudioItem, statistics: TransferStatistics?,
                progress: @escaping @Sendable (UploadProgress) async -> Void) async throws -> UploadResult
}
