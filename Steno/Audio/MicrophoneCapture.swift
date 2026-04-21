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
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        inputFormat = format
        originalFormat = format
        logger.info("Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        installTap(format: format, bufferHandler: bufferHandler)

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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        originalFormat = nil
        isCapturing = false
        logger.info("Microphone capture stopped")
    }

    // MARK: - Device Change Handling

    private func installTap(format: AVAudioFormat, bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            bufferHandler(buffer, time)
        }
    }

    private func handleConfigurationChange(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        guard isCapturing else { return }

        // Engine is already stopped by the system when this fires
        engine.inputNode.removeTap(onBus: 0)

        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            logger.error("New audio device has invalid format, cannot restart")
            return
        }

        logger.info("New mic format: \(newFormat.sampleRate)Hz, \(newFormat.channelCount)ch")

        // If format changed, set up a converter so downstream (writer) keeps getting
        // buffers in the original format it was opened with.
        if let origFormat = originalFormat,
           (newFormat.sampleRate != origFormat.sampleRate || newFormat.channelCount != origFormat.channelCount) {

            converter = AVAudioConverter(from: newFormat, to: origFormat)
            logger.info("Installed format converter: \(newFormat.sampleRate)Hz → \(origFormat.sampleRate)Hz")
            inputFormat = origFormat  // downstream still sees original format

            let capturedConverter = converter!
            let capturedOrigFormat = origFormat
            let capturedLogger = logger

            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: newFormat) { buffer, time in
                // Convert to original format so writer doesn't break
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * capturedOrigFormat.sampleRate / newFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: capturedOrigFormat, frameCapacity: frameCapacity) else {
                    capturedLogger.error("Failed to allocate conversion buffer")
                    return
                }
                var error: NSError?
                capturedConverter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if let error {
                    capturedLogger.error("Format conversion failed: \(error)")
                    return
                }
                bufferHandler(converted, time)
            }
        } else {
            converter = nil
            inputFormat = newFormat
            installTap(format: newFormat, bufferHandler: bufferHandler)
        }

        engine.prepare()
        do {
            try engine.start()
            logger.info("Engine restarted after device change")
        } catch {
            logger.error("Failed to restart engine after device change: \(error)")
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
