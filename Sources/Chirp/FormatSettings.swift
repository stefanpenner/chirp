// FormatSettings.swift — User toggles for dictation auto-formatting.
// Persisted in UserDefaults; pure defaults for tests.

import Foundation

enum FormatSettings {
    static let relativeDatesKey = "chirp.format.expandRelativeDates"
    static let numberedListsKey = "chirp.format.expandNumberedLists"
    static let bulletsKey = "chirp.format.expandBullets"

    /// Test overrides (nil = read UserDefaults).
    nonisolated(unsafe) static var testExpandRelativeDates: Bool?
    nonisolated(unsafe) static var testExpandNumberedLists: Bool?
    nonisolated(unsafe) static var testExpandBullets: Bool?

    static func resetTestOverrides() {
        testExpandRelativeDates = nil
        testExpandNumberedLists = nil
        testExpandBullets = nil
    }

    static var expandRelativeDates: Bool {
        get {
            if let t = testExpandRelativeDates { return t }
            if UserDefaults.standard.object(forKey: relativeDatesKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: relativeDatesKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: relativeDatesKey) }
    }

    static var expandNumberedLists: Bool {
        get {
            if let t = testExpandNumberedLists { return t }
            if UserDefaults.standard.object(forKey: numberedListsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: numberedListsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: numberedListsKey) }
    }

    static var expandBullets: Bool {
        get {
            if let t = testExpandBullets { return t }
            if UserDefaults.standard.object(forKey: bulletsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: bulletsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: bulletsKey) }
    }
}
