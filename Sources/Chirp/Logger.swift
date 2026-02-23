// Logger.swift — Lightweight structured logging via Apple's unified logging.
// Usage: Log.model.error("message"), Log.cloud.info("message"), etc.

import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.chirp"

    static let general = os.Logger(subsystem: subsystem, category: "general")
    static let audio = os.Logger(subsystem: subsystem, category: "audio")
    static let transcription = os.Logger(subsystem: subsystem, category: "transcription")
    static let cloud = os.Logger(subsystem: subsystem, category: "cloud")
    static let model = os.Logger(subsystem: subsystem, category: "model")
    static let speaker = os.Logger(subsystem: subsystem, category: "speaker")
}
