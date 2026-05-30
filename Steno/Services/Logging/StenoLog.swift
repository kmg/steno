import Foundation
import os

/// Subsystem names used for log partitioning and Debug-tab filtering.
/// See ADR-0007 for the rationale on per-subsystem rather than per-file categorization.
enum LogSubsystem: String, CaseIterable, Hashable, Identifiable {
    case audio
    case transcription
    case diarization
    case storage
    case app

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .audio: return "Audio"
        case .transcription: return "Transcription"
        case .diarization: return "Diarization"
        case .storage: return "Storage"
        case .app: return "App"
        }
    }
}

enum LogLevel: String, CaseIterable, Hashable, Identifiable, Comparable {
    case debug
    case info
    case warning
    case error

    var id: String { rawValue }

    var order: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.order < rhs.order
    }
}

struct LogEvent: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let subsystem: LogSubsystem
    let message: String

    init(level: LogLevel, subsystem: LogSubsystem, message: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.message = message
    }
}

/// Per-subsystem logger. Writes to os_log (for Console.app + log stream) AND
/// to LogStore (for the in-app Debug tab). Thread-safe — designed for audio-IO use.
struct StenoLogger {
    let subsystem: LogSubsystem
    private let osLogger: Logger

    init(subsystem: LogSubsystem) {
        self.subsystem = subsystem
        self.osLogger = Logger(subsystem: "com.kmganesh.steno", category: subsystem.rawValue)
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
        LogStore.shared.append(LogEvent(level: .debug, subsystem: subsystem, message: message))
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        LogStore.shared.append(LogEvent(level: .info, subsystem: subsystem, message: message))
    }

    func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        LogStore.shared.append(LogEvent(level: .warning, subsystem: subsystem, message: message))
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        LogStore.shared.append(LogEvent(level: .error, subsystem: subsystem, message: message))
    }
}

/// Static facade — call as `StenoLog.audio.info("...")` from anywhere.
enum StenoLog {
    static let audio = StenoLogger(subsystem: .audio)
    static let transcription = StenoLogger(subsystem: .transcription)
    static let diarization = StenoLogger(subsystem: .diarization)
    static let storage = StenoLogger(subsystem: .storage)
    static let app = StenoLogger(subsystem: .app)
}
