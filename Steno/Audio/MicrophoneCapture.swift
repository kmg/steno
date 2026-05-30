import AVFoundation
import CoreAudio
import os

/// Captures microphone audio via AVAudioEngine.
///
/// Instrumentation (see ADR-0012): counts tap-callback invocations and runs
/// a "silent tap detector" timer that warns if no buffers arrive for >10s
/// while capturing. The 2026-05-30 09:06 incident produced an empty WAV;
/// `AudioFileWriter`'s counter (ADR-0011) would catch all-buffer-dropped
/// scenarios, but if the tap callback never fires at all (the actual 09:06
/// failure mode), the writer never sees buffers to drop. This detector
/// catches that case at the source, in real time.
///
/// Thread safety: `bufferHandler` is called on the audio IO thread.
/// `start`/`stop` are called from the main thread via RecordingPipeline.
final class MicrophoneCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let log = StenoLog.audio

    private(set) var isCapturing = false
    private(set) var inputFormat: AVAudioFormat?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Serial queue for device change handling. All pendingRestart access is serialized here
    /// to prevent use-after-free from concurrent Core Audio listener callbacks.
    private let restartQueue = DispatchQueue(label: "com.kmganesh.steno.mic-restart")
    private var pendingRestart: DispatchWorkItem?  // only accessed on restartQueue

    // Instrumentation — all guarded by counterLock.
    private let counterLock = NSLock()
    private var buffersReceived: Int = 0
    private var lastBufferAt: Date?
    private var captureStartedAt: Date?

    /// Silent-tap detector. Runs on the main run loop while capturing; warns
    /// when the tap callback hasn't fired in >10s. Invalidated on stop().
    private var silentTapTimer: Timer?
    private let silentTapThreshold: TimeInterval = 10.0
    private let silentTapCheckInterval: TimeInterval = 5.0

    /// Snapshot of the tap-invocation counter, for tests and Debug-tab display.
    var buffersReceivedCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return buffersReceived
    }

    init() {
        // Register the input-device-change listener ONCE per instance lifetime.
        // Re-registering on every start/restart cycle leaks listeners — see
        // SystemAudioCapture's init() for the full explanation.
        installInputDeviceListener()
    }

    /// Stored handler for use with RecordingPipeline
    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Called after mic restarts due to device change. Passes the new format.
    var onDeviceChange: ((AVAudioFormat) -> Void)?

    /// Called when mic restart fails. Pipeline should stop recording gracefully.
    var onDeviceChangeFailed: (() -> Void)?

    /// Start using stored bufferHandler
    func startWithHandler() throws {
        guard let handler = bufferHandler else {
            throw CaptureError.invalidFormat
        }
        try start { buffer, _ in handler(buffer) }
    }

    /// Start capturing microphone audio. Calls handler on the audio thread with PCM buffers.
    ///
    /// Format strategy chain (fresh engine per attempt):
    /// 1. outputFormat(forBus: 0) — engine's preferred format
    /// 2. nil — let the engine choose (matches hardware exactly)
    /// 3. 48kHz mono — safe fallback for any device
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        if isCapturing { stop() }

        let strategies: [(String, (AVAudioEngine) -> AVAudioFormat?)] = [
            ("outputFormat", { engine in
                let fmt = engine.inputNode.outputFormat(forBus: 0)
                guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return nil }
                return fmt
            }),
            ("nil (engine chooses)", { _ in nil }),
            ("48kHz mono fallback", { _ in
                AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
            })
        ]

        for (name, getFormat) in strategies {
            engine = AVAudioEngine()

            // Wrap entire engine setup in exception catcher.
            // AVAudioEngine can throw NSException from inputNode/mainMixerNode
            // access during device transitions (documented AVAudioEngine bug).
            do {
                var capturedFormat: AVAudioFormat?
                try ObjCExceptionCatcher.catching {
                    _ = self.engine.mainMixerNode
                    let inputNode = self.engine.inputNode
                    let format = getFormat(self.engine)

                    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
                        self?.recordTapInvocation()
                        bufferHandler(buffer, time)
                    }

                    let actualFormat = inputNode.outputFormat(forBus: 0)
                    if actualFormat.sampleRate > 0, actualFormat.channelCount > 0 {
                        capturedFormat = actualFormat
                    }
                }

                guard let actualFormat = capturedFormat else {
                    log.warning("Invalid format after installTap with \(name)")
                    engine.inputNode.removeTap(onBus: 0)
                    continue
                }

                inputFormat = actualFormat
                log.info("Mic format (\(name)): \(actualFormat.sampleRate)Hz, \(actualFormat.channelCount)ch")
            } catch {
                log.warning("Engine setup failed with \(name): \(error.localizedDescription)")
                continue
            }

            engine.prepare()
            try engine.start()
            isCapturing = true
            resetInstrumentation()
            // Input-device-change listener is registered once in init() — see comment there.
            startSilentTapTimer()
            log.info("Microphone capture started")
            return
        }

        throw CaptureError.invalidFormat
    }

    /// Called on every tap-callback invocation from the audio IO thread.
    /// Lock-hold time is minimal — just two integer/Date writes.
    private func recordTapInvocation() {
        counterLock.lock()
        buffersReceived += 1
        lastBufferAt = Date()
        counterLock.unlock()
    }

    /// Reset counters and start time. Called from start() after a successful engine start.
    private func resetInstrumentation() {
        counterLock.lock()
        buffersReceived = 0
        lastBufferAt = nil
        captureStartedAt = Date()
        counterLock.unlock()
    }

    /// Schedule the silent-tap detector. Runs on the main run loop; reads
    /// counters under counterLock; emits a warning if the tap has been
    /// silent for longer than silentTapThreshold while isCapturing.
    private func startSilentTapTimer() {
        silentTapTimer?.invalidate()
        silentTapTimer = Timer.scheduledTimer(withTimeInterval: silentTapCheckInterval, repeats: true) { [weak self] _ in
            self?.checkSilentTap()
        }
    }

    private func stopSilentTapTimer() {
        silentTapTimer?.invalidate()
        silentTapTimer = nil
    }

    private func checkSilentTap() {
        guard isCapturing else { return }

        counterLock.lock()
        let count = buffersReceived
        let last = lastBufferAt
        let started = captureStartedAt
        counterLock.unlock()

        guard let started = started else { return }

        let now = Date()
        let referenceTime = last ?? started
        let gap = now.timeIntervalSince(referenceTime)

        guard gap > silentTapThreshold else { return }

        if count == 0 {
            log.warning("Silent mic tap: zero buffers received since start (\(String(format: "%.1f", gap))s ago). Recording will be empty.")
        } else {
            log.warning("Silent mic tap: no buffers in \(String(format: "%.1f", gap))s (\(count) received total). Tap may have stalled.")
        }
    }

    /// Restart mic capture after a device change.
    /// If restart fails, calls onDeviceChangeFailed so the pipeline can stop gracefully.
    private func restart() {
        guard isCapturing, let handler = bufferHandler else { return }
        let changeCallback = onDeviceChange
        let failCallback = onDeviceChangeFailed
        log.info("Restarting mic capture after device change")
        stop()
        do {
            bufferHandler = handler
            onDeviceChange = changeCallback
            onDeviceChangeFailed = failCallback
            try startWithHandler()
            if let newFormat = inputFormat {
                changeCallback?(newFormat)
            }
        } catch {
            log.error("Mic restart failed: \(error.localizedDescription). Stopping recording.")
            failCallback?()
        }
    }

    func stop() {
        stopSilentTapTimer()
        // Input-device-change listener is NOT removed here — it stays registered for
        // the instance lifetime (cleaned up in deinit). The listener body gates on
        // isCapturing so it only schedules a restart when actually recording.
        guard isCapturing else { return }
        removeTapSafely()
        engine.stop()
        isCapturing = false

        counterLock.lock()
        let count = buffersReceived
        counterLock.unlock()
        log.info("Microphone capture stopped: \(count) buffers received")
    }

    deinit {
        stop()
        removeInputDeviceListener()
    }

    private func removeTapSafely() {
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Input device change listener

    private func installInputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Gate on isCapturing — when not recording, ignore the notification.
            // This avoids noisy logs and prevents useless restart attempts.
            guard self.isCapturing else { return }
            self.log.info("Default input device changed")
            // Serialize on restartQueue. The listener callback runs on Core Audio's
            // thread — all mutable state access must happen on our queue.
            self.restartQueue.async { [weak self] in
                guard let self else { return }
                self.pendingRestart?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.restart()
                }
                self.pendingRestart = work
                // 2 second delay: let CoreAudio finish its internal aggregate device
                // reconfiguration (especially AirPods HFP negotiation) before we
                // create a fresh engine. Shorter delays race with the system.
                self.restartQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        if status == noErr {
            deviceListenerBlock = block
        }
    }

    private func removeInputDeviceListener() {
        // Cancel any pending restart. No sync needed — either we're already on
        // restartQueue (called from restart→stop) or recording is ending (no races).
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let block = deviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        deviceListenerBlock = nil
    }

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
