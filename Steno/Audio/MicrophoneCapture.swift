import AVFoundation
import CoreAudio
import os

/// Captures microphone audio via AVAudioEngine.
///
/// Thread safety: `bufferHandler` is called on the audio IO thread.
/// `start`/`stop` are called from the main thread via RecordingPipeline.
final class MicrophoneCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "MicrophoneCapture")

    private(set) var isCapturing = false
    private(set) var inputFormat: AVAudioFormat?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var pendingRestart: DispatchWorkItem?

    /// Stored handler for use with RecordingPipeline
    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Called after mic restarts due to device change. Passes the new format.
    /// RecordingPipeline uses this to start a new WAV segment at the new format.
    var onDeviceChange: ((AVAudioFormat) -> Void)?

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

                    inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                        bufferHandler(buffer, time)
                    }

                    let actualFormat = inputNode.outputFormat(forBus: 0)
                    if actualFormat.sampleRate > 0, actualFormat.channelCount > 0 {
                        capturedFormat = actualFormat
                    }
                }

                guard let actualFormat = capturedFormat else {
                    logger.warning("Invalid format after installTap with \(name)")
                    engine.inputNode.removeTap(onBus: 0)
                    continue
                }

                inputFormat = actualFormat
                logger.info("Mic format (\(name)): \(actualFormat.sampleRate)Hz, \(actualFormat.channelCount)ch")
            } catch {
                logger.warning("Engine setup failed with \(name): \(error.localizedDescription)")
                continue
            }

            engine.prepare()
            try engine.start()
            isCapturing = true
            installInputDeviceListener()
            logger.info("Microphone capture started")
            return
        }

        throw CaptureError.invalidFormat
    }

    /// Restart mic capture after a device change (e.g., AirPods connected mid-recording).
    private func restart() {
        guard isCapturing, let handler = bufferHandler else { return }
        let changeCallback = onDeviceChange
        logger.info("Restarting mic capture after device change")
        stop()
        do {
            bufferHandler = handler
            onDeviceChange = changeCallback
            try startWithHandler()
            if let newFormat = inputFormat {
                changeCallback?(newFormat)
            }
        } catch {
            logger.error("Failed to restart mic after device change: \(error.localizedDescription)")
        }
    }

    func stop() {
        removeInputDeviceListener()
        guard isCapturing else { return }
        removeTapSafely()
        engine.stop()
        isCapturing = false
        logger.info("Microphone capture stopped")
    }

    private func removeTapSafely() {
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Input device change listener

    private func installInputDeviceListener() {
        removeInputDeviceListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.logger.info("Default input device changed")
            // Debounce: cancel any pending restart, schedule a new one.
            // Multiple notifications within 500ms collapse to a single restart.
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restart()
            }
            self.pendingRestart = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: work)
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
