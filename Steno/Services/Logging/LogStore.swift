import Foundation

/// In-memory ring buffer for LogEvents, partitioned by subsystem.
/// NSLock-protected — safe to call from audio-IO threads.
/// See ADR-0007 (Debug tab) and ADR-0006 Decision E (NSLock-over-actors for audio threads).
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    /// Max events retained per subsystem. Older events are evicted on append.
    /// Total worst-case memory: capacity × number-of-subsystems × ~200 bytes.
    static let defaultCapacity = 200

    private let lock = NSLock()
    private var buffers: [LogSubsystem: [LogEvent]] = [:]
    private let capacity: Int

    init(capacity: Int = LogStore.defaultCapacity) {
        self.capacity = capacity
        for subsystem in LogSubsystem.allCases {
            buffers[subsystem] = []
        }
    }

    func append(_ event: LogEvent) {
        lock.lock()
        defer { lock.unlock() }
        var ring = buffers[event.subsystem, default: []]
        ring.append(event)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        buffers[event.subsystem] = ring
    }

    /// Snapshot all events across all subsystems, merged and sorted by timestamp (oldest first).
    func snapshot() -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        let merged = buffers.values.flatMap { $0 }
        return merged.sorted { $0.timestamp < $1.timestamp }
    }

    /// Snapshot for a specific filter (subsystems + minimum level), sorted by timestamp.
    func snapshot(subsystems: Set<LogSubsystem>, minLevel: LogLevel) -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        let merged = buffers
            .filter { subsystems.contains($0.key) }
            .values
            .flatMap { $0 }
            .filter { $0.level >= minLevel }
        return merged.sorted { $0.timestamp < $1.timestamp }
    }

    /// Count of events currently buffered for a subsystem.
    func count(for subsystem: LogSubsystem) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers[subsystem]?.count ?? 0
    }

    /// Most recent event timestamp for a subsystem, if any.
    func lastEventTime(for subsystem: LogSubsystem) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return buffers[subsystem]?.last?.timestamp
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for subsystem in LogSubsystem.allCases {
            buffers[subsystem] = []
        }
    }

    /// Render a snapshot as plain text for clipboard/share.
    func exportText(subsystems: Set<LogSubsystem>, minLevel: LogLevel) -> String {
        let events = snapshot(subsystems: subsystems, minLevel: minLevel)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return events.map { event in
            "\(formatter.string(from: event.timestamp)) [\(event.level.rawValue.uppercased())] \(event.subsystem.rawValue): \(event.message)"
        }.joined(separator: "\n")
    }
}
