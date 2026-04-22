import AVFoundation
import os

/// Captures microphone audio via AVAudioEngine.
///
/// Thread safety: `bufferHandler` is called on the audio IO thread.
/// `start`/`stop` are called from the main thread via RecordingPipeline.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "MicrophoneCapture")

    private(set) var isCapturing = false
    private(set) var inputFormat: AVAudioFormat?

    /// Stored handler for use with RecordingPipeline
    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Start using stored bufferHandler
    func startWithHandler() throws {
        guard let handler = bufferHandler else {
            throw CaptureError.invalidFormat
        }
        try start { buffer, _ in handler(buffer) }
    }

    /// Start capturing microphone audio. Calls handler on the audio thread with PCM buffers.
    func start(bufferHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        // Clean up any leftover state from a previous failed start.
        if isCapturing { stop() }
        removeTapSafely()

        let inputNode = engine.inputNode
        // Use inputFormat (hardware format), not outputFormat (tap output format).
        // These can differ with Bluetooth devices. installTap requires the format
        // to match the actual hardware format exactly, or it throws -10868.
        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        inputFormat = format
        logger.info("Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        try ObjCExceptionCatcher.catching {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                bufferHandler(buffer, time)
            }
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        logger.info("Microphone capture started")
    }

    func stop() {
        guard isCapturing else { return }
        removeTapSafely()
        engine.stop()
        isCapturing = false
        logger.info("Microphone capture stopped")
    }

    /// Remove any existing tap. Safe to call even if no tap is installed.
    private func removeTapSafely() {
        engine.inputNode.removeTap(onBus: 0)
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
