import AVFoundation
import os

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "MicrophoneCapture")

    private(set) var isCapturing = false
    private(set) var inputFormat: AVAudioFormat?

    /// Start capturing microphone audio. Calls handler on the audio thread with PCM buffers.
    func start(bufferHandler: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        inputFormat = format
        logger.info("Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            bufferHandler(buffer, time)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        logger.info("Microphone capture started")
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        logger.info("Microphone capture stopped")
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
