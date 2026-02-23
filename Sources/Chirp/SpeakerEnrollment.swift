// SpeakerEnrollment.swift — Speaker enrollment data persisted to UserDefaults.
// Stores the reference embedding and enrollment state.

import Foundation

public struct SpeakerEnrollment: Codable, Sendable, Equatable {
    public var referenceEmbedding: [Float]?
    public var phraseCount: Int = 0
    public var enrolledAt: Date?
    public var isEnabled: Bool = false
    public var threshold: Float = 0.25

    public var isEnrolled: Bool {
        referenceEmbedding != nil && phraseCount > 0
    }

    public init() {}

    // MARK: - Persistence

    private static let userDefaultsKey = "chirp.speakerEnrollment"

    public static var saved: SpeakerEnrollment {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return SpeakerEnrollment()
        }
        do {
            return try JSONDecoder().decode(SpeakerEnrollment.self, from: data)
        } catch {
            Log.speaker.error("Failed to decode SpeakerEnrollment, using defaults: \(error.localizedDescription)")
            return SpeakerEnrollment()
        }
    }

    public func save() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            Log.speaker.error("Failed to encode SpeakerEnrollment: \(error.localizedDescription)")
        }
    }
}
