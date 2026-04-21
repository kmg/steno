import AVFoundation
import os

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "MicrophoneCapture")

    private(set) var isCapturing = false
    private(set) var inputFormat: AVAudioFormat?

    /// Stored handler for use with RecordingPipeline
    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Converter for resampling after device changes
    private var converter: AVAudioConverter?
    private var originalFormat: AVAudioFormat?

    private var configObserver: NSObjectProtocol?

    /// Start using stored bufferHandler
    func startWithHandler() throws {
        guard let handler = bufferHandler else {
            throw CaptureError.invalidFormat
        }
        try start { buffer, _ in handler(buffer) }
    }

    /// Start capturing microphone audio. Calls handler on the audio thread with PCM buffers.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        // Clean up any leftover state from a previous failed start. installTap throws
        // an uncatchable NSException if a tap already exists on the bus.
        if isCapturing {
            stop()
        }
        removeTapSafely()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        inputFormat = format
        originalFormat = format
        logger.info("Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        // Pass explicit format on initial start (known good, no device transition in flight).
        removeTapSafely()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            bufferHandler(buffer, time)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        logger.info("Microphone capture started")

        // Listen for audio device changes (headphones plugged in/out, Bluetooth connect, etc.)
        let capturedLogger = logger
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            capturedLogger.info("Audio device configuration changed, restarting engine")
            self?.handleConfigurationChange(bufferHandler: bufferHandler)
        }
    }

    func stop() {
        guard isCapturing else { return }
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        removeTapSafely()
        engine.stop()
        converter = nil
        originalFormat = nil
        isCapturing = false
        logger.info("Microphone capture stopped")
    }

    // MARK: - Device Change Handling

    /// Remove any existing tap. Safe to call even if no tap is installed.
    /// Prevents NSException from installTap when a tap already exists.
    private func removeTapSafely() {
        engine.inputNode.removeTap(onBus: 0)
    }

    private func handleConfigurationChange(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        guard isCapturing else { return }

        // Engine is already stopped by the system when this notification fires.
        removeTapSafely()
        converter = nil

        // Pass nil for format — let the engine use the hardware's native format.
        // Passing an explicit format triggers SetOutputFormat which throws an uncatchable
        // NSException during device transitions (e.g. AirPods connect at 16kHz while
        // built-in mic was 48kHz). Passing nil avoids SetOutputFormat entirely.
        let capturedOrigFormat = originalFormat
        let capturedLogger = logger

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            guard let origFormat = capturedOrigFormat else {
                bufferHandler(buffer, time)
                return
            }

            let bufferFormat = buffer.format

            // If buffer format matches original, pass through directly
            if bufferFormat.sampleRate == origFormat.sampleRate && bufferFormat.channelCount == origFormat.channelCount {
                bufferHandler(buffer, time)
                return
            }

            // Format changed — convert to original format so writer stays coherent
            // Lazily create converter on first buffer (we now know the actual hardware format)
            if self?.converter == nil {
                self?.converter = AVAudioConverter(from: bufferFormat, to: origFormat)
                capturedLogger.info("Device changed: \(bufferFormat.sampleRate)Hz → converting to \(origFormat.sampleRate)Hz")
            }

            guard let conv = self?.converter else {
                bufferHandler(buffer, time)
                return
            }

            let ratio = origFormat.sampleRate / bufferFormat.sampleRate
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
                capturedLogger.error("Format conversion failed: \(error)")
                return
            }
            bufferHandler(converted, time)
        }

        // Read format after installing tap (reflects what the engine will actually deliver)
        let postTapFormat = engine.inputNode.outputFormat(forBus: 0)
        if postTapFormat.sampleRate > 0 {
            logger.info("Post-tap format: \(postTapFormat.sampleRate)Hz, \(postTapFormat.channelCount)ch")
        }

        engine.prepare()
        do {
            try engine.start()
            logger.info("Engine restarted after device change")
        } catch {
            logger.error("Failed to restart engine after device change: \(error)")
            // Recording continues silently dead — audio from before the switch is preserved.
            // Better than crashing.
        }
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
