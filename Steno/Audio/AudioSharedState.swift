import Foundation

/// Thread-safe shared state for audio buffers between Core Audio IO thread and mic callback.
/// Lives outside @MainActor to avoid actor isolation crashes.
final class AudioSharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _systemSamples: [Float] = []
    private var _ready = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ready
    }

    func appendSystemSamples(_ samples: [Float]) {
        lock.lock()
        _systemSamples.append(contentsOf: samples)
        _ready = true
        lock.unlock()
    }

    func consumeSystemSamples(count: Int) -> [Float] {
        lock.lock()
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
        lock.unlock()
    }
}
