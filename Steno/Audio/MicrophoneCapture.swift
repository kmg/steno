import AVFoundation
import os

/// Captures microphone audio via AVAudioEngine. Handles mid-recording device
/// changes (AirPods, Bluetooth headsets, headphone hotplug) by creating a fresh
/// engine and converting audio to the original recording format.
///
/// Recovery design:
/// - Fresh AVAudioEngine on every device change (reusing a stuck engine fails)
/// - ObjC exception wrapper around installTap (throws NSException, not Swift Error)
/// - 150ms debounce to coalesce rapid notifications
/// - 1s quiescence window after engine start to ignore self-induced config changes
///   (Bluetooth A2DP↔HFP profile switches trigger a config change after every start)
/// - Circuit breaker: 4 config changes in 5s = give up, surface error
/// - Generation counter to discard stale recovery callbacks
final class MicrophoneCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "MicrophoneCapture")

    private(set) var isCapturing = false
    private(set) var inputFormat: AVAudioFormat?

    /// The format the recording was started with. All post-device-change audio
    /// gets converted back to this so the file writer stays coherent.
    private var originalFormat: AVAudioFormat?

    /// Converter for resampling after device changes. Protected by converterLock.
    private var converter: AVAudioConverter?
    private let converterLock = NSLock()

    private var configObserver: NSObjectProtocol?

    /// Serial queue for all recovery work. Prevents concurrent config change handling.
    private let recoveryQueue = DispatchQueue(label: "com.kmganesh.steno.mic-recovery")

    // MARK: - Recovery policy

    private static let debounceInterval: TimeInterval = 0.15
    private static let quiescenceWindow: TimeInterval = 1.0
    private static let burstWindow: TimeInterval = 5.0
    private static let burstLimit = 4
    private static let engineTeardownDelay: TimeInterval = 0.3

    /// Generation counter — incremented on each recovery. Stale callbacks check this.
    private var generation: UInt64 = 0

    /// Timestamp of last successful engine start. Config changes within quiescence
    /// window after start are ignored (Bluetooth profile renegotiation noise).
    private var lastEngineStartTime: Date = .distantPast

    /// Timestamps of recent config changes for burst detection.
    private var recentConfigChanges: [Date] = []

    /// Retained reference to old engine so CoreAudio callbacks don't outlive it.
    private var retainedOldEngine: AVAudioEngine?
    private var teardownWorkItem: DispatchWorkItem?

    /// Called on main actor when recovery fails permanently (burst breaker tripped,
    /// engine won't restart). Pipeline should show degraded state.
    var onCaptureDegraded: (() -> Void)?

    // MARK: - Public API

    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func startWithHandler() throws {
        guard let handler = bufferHandler else {
            throw CaptureError.invalidFormat
        }
        try start { buffer, _ in handler(buffer) }
    }

    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        if isCapturing { stop() }

        // Always start with a fresh engine
        engine = AVAudioEngine()
        generation += 1
        recentConfigChanges = []

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        inputFormat = format
        originalFormat = format
        logger.info("Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        try installTapSafely(on: engine, format: format, bufferHandler: bufferHandler)

        engine.prepare()
        try engine.start()
        isCapturing = true
        lastEngineStartTime = Date()
        logger.info("Microphone capture started")

        installConfigObserver(bufferHandler: bufferHandler)
    }

    func stop() {
        guard isCapturing else { return }
        removeConfigObserver()
        removeTapSafely(from: engine)
        engine.stop()
        converterLock.lock()
        converter = nil
        converterLock.unlock()
        originalFormat = nil
        isCapturing = false
        logger.info("Microphone capture stopped")
    }

    // MARK: - Tap installation with ObjC exception safety

    /// Install a tap, catching any NSException (format mismatch, duplicate tap).
    private func installTapSafely(
        on eng: AVAudioEngine,
        format: AVAudioFormat,
        bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        removeTapSafely(from: eng)

        // Build a mono tap format from the input to normalize multi-channel devices
        let tapFormat = monoFormat(from: format) ?? format

        try ObjCExceptionCatcher.catching {
            eng.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, time in
                bufferHandler(buffer, time)
            }
        }
    }

    private func removeTapSafely(from eng: AVAudioEngine) {
        eng.inputNode.removeTap(onBus: 0)
    }

    private func monoFormat(from format: AVAudioFormat) -> AVAudioFormat? {
        guard format.channelCount > 1 else { return format }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    // MARK: - Configuration change observer

    private func installConfigObserver(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        removeConfigObserver()

        let capturedLogger = logger
        let observerQueue = OperationQueue()
        observerQueue.underlyingQueue = recoveryQueue
        observerQueue.maxConcurrentOperationCount = 1

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: observerQueue
        ) { [weak self] _ in
            capturedLogger.info("Audio config change notification received")
            self?.scheduleRecovery(bufferHandler: bufferHandler)
        }
    }

    private func removeConfigObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    // MARK: - Recovery orchestration

    private func scheduleRecovery(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        // Already on recoveryQueue via the observer's OperationQueue

        // Quiescence: ignore config changes shortly after engine start.
        // Bluetooth profile switches cause a benign config change after every start.
        if Date().timeIntervalSince(lastEngineStartTime) < Self.quiescenceWindow {
            // Check if format actually changed before ignoring
            let liveFormat = engine.inputNode.outputFormat(forBus: 0)
            if let orig = originalFormat,
               liveFormat.sampleRate == orig.sampleRate,
               liveFormat.channelCount == orig.channelCount {
                logger.info("Ignoring config change within quiescence window (format unchanged)")
                return
            }
        }

        // Burst detection: too many rapid changes = give up
        let now = Date()
        recentConfigChanges.append(now)
        recentConfigChanges = recentConfigChanges.filter { now.timeIntervalSince($0) < Self.burstWindow }
        if recentConfigChanges.count >= Self.burstLimit {
            logger.error("Circuit breaker: \(self.recentConfigChanges.count) config changes in \(Self.burstWindow)s, stopping recovery")
            isCapturing = false
            onCaptureDegraded?()
            return
        }

        // Debounce: coalesce rapid notifications
        let targetGeneration = generation + 1
        generation = targetGeneration

        recoveryQueue.asyncAfter(deadline: .now() + Self.debounceInterval) { [weak self] in
            guard let self, self.generation == targetGeneration else { return }
            self.performRecovery(bufferHandler: bufferHandler)
        }
    }

    private func performRecovery(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        guard isCapturing else { return }

        logger.info("Performing engine recovery")

        // Remove observer for the old engine
        removeConfigObserver()

        // Tear down old engine
        let oldEngine = engine
        removeTapSafely(from: oldEngine)
        oldEngine.stop()

        // Retain old engine briefly so in-flight CoreAudio callbacks don't crash
        retainedOldEngine = oldEngine
        teardownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.retainedOldEngine = nil
        }
        teardownWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.engineTeardownDelay, execute: workItem)

        // Create fresh engine
        let newEngine = AVAudioEngine()
        engine = newEngine

        let newFormat = newEngine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            logger.error("New audio device has invalid format after recovery")
            isCapturing = false
            onCaptureDegraded?()
            return
        }

        logger.info("Recovery format: \(newFormat.sampleRate)Hz, \(newFormat.channelCount)ch")

        // Set up format conversion if needed
        let needsConversion: Bool
        if let orig = originalFormat,
           (newFormat.sampleRate != orig.sampleRate || newFormat.channelCount != orig.channelCount) {
            converterLock.lock()
            converter = AVAudioConverter(from: newFormat, to: orig)
            if converter == nil {
                logger.error("Cannot create format converter: \(newFormat) → \(orig)")
            } else {
                logger.info("Format converter: \(newFormat.sampleRate)Hz → \(orig.sampleRate)Hz")
            }
            converterLock.unlock()
            needsConversion = true
            inputFormat = orig
        } else {
            converterLock.lock()
            converter = nil
            converterLock.unlock()
            needsConversion = false
            inputFormat = newFormat
        }

        // Install tap with converting wrapper if needed
        do {
            if needsConversion, let origFormat = originalFormat {
                let capturedConverterLock = converterLock
                let capturedLogger = logger

                try ObjCExceptionCatcher.catching {
                    let tapFormat = self.monoFormat(from: newFormat) ?? newFormat
                    newEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, time in
                        capturedConverterLock.lock()
                        let conv = self?.converter
                        capturedConverterLock.unlock()

                        guard let conv else {
                            // No converter available — pass through (may cause writer issues,
                            // but better than dropping audio entirely)
                            bufferHandler(buffer, time)
                            return
                        }

                        let ratio = origFormat.sampleRate / buffer.format.sampleRate
                        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                        guard let converted = AVAudioPCMBuffer(pcmFormat: origFormat, frameCapacity: frameCapacity) else {
                            capturedLogger.error("Failed to allocate conversion buffer")
                            return
                        }

                        var error: NSError?
                        conv.convert(to: converted, error: &error) { _, outStatus in
                            outStatus.pointee = .haveData
                            return buffer
                        }
                        if let error {
                            capturedLogger.error("Format conversion error: \(error)")
                            return
                        }
                        bufferHandler(converted, time)
                    }
                }
            } else {
                try installTapSafely(on: newEngine, format: newFormat, bufferHandler: bufferHandler)
            }
        } catch {
            logger.error("Failed to install tap after recovery: \(error)")
            isCapturing = false
            onCaptureDegraded?()
            return
        }

        newEngine.prepare()
        do {
            try newEngine.start()
            lastEngineStartTime = Date()
            logger.info("Engine recovered successfully")
        } catch {
            logger.error("Failed to start engine after recovery: \(error)")
            isCapturing = false
            onCaptureDegraded?()
            return
        }

        // Observe config changes on the new engine
        installConfigObserver(bufferHandler: bufferHandler)
    }

    // MARK: - Errors

    enum CaptureError: LocalizedError {
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "Microphone audio format is invalid"
            }
        }
    }
}
