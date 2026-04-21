import Foundation

/// Thread-safe shared state for audio buffers between Core Audio IO thread and mic callback.
/// Lives outside @MainActor to avoid actor isolation crashes.
final class AudioSharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _systemSamples: [Float] = []
    private var _ready = false
    private var _lastAppendTime: UInt64 = 0

    /// Maximum age of system audio samples before they're considered stale.
    /// If the system audio tap stops delivering (e.g. output device changed),
    /// old samples shouldn't be mixed into fresh mic audio at wrong timestamps.
    private static let maxStalenessNanos: UInt64 = 500_000_000 // 500ms

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ready
    }

    func appendSystemSamples(_ samples: [Float]) {
        lock.lock()
        _systemSamples.append(contentsOf: samples)
        _lastAppendTime = mach_absolute_time()
        _ready = true
        lock.unlock()
    }

    func consumeSystemSamples(count: Int) -> [Float] {
        lock.lock()

        // Discard stale samples if system audio stopped delivering (e.g. output device changed).
        // Mixing stale system audio with fresh mic audio produces garbled timestamps.
        if _lastAppendTime > 0 {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let elapsed = (mach_absolute_time() - _lastAppendTime) * UInt64(info.numer) / UInt64(info.denom)
            if elapsed > Self.maxStalenessNanos {
                _systemSamples.removeAll()
                lock.unlock()
                return []
            }
        }

        let available = min(count, _systemSamples.count)
        let result: [Float]
        if available > 0 {
            result = Array(_systemSamples.prefix(available))
            _systemSamples.removeFirst(available)
        } else {
            result = []
        }
        lock.unlock()
        return result
    }

    private var _callbackCount = 0
    private var _writerStarted = false

    var callbackCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _callbackCount }
        set { lock.lock(); _callbackCount = newValue; lock.unlock() }
    }

    var writerStarted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _writerStarted }
        set { lock.lock(); _writerStarted = newValue; lock.unlock() }
    }

    func reset() {
        lock.lock()
        _systemSamples = []
        _ready = false
        _callbackCount = 0
        _writerStarted = false
        _lastAppendTime = 0
        lock.unlock()
    }
}
