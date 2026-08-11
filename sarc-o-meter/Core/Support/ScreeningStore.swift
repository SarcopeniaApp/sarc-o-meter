//  ScreeningStore.swift
//
//  Persists the completed ScreeningRecord (UserDefaults, small JSON blob) so the
//  app can jump straight to the tracker on the next launch. Single source of
//  truth for "has the user finished screening yet?".

import Foundation

enum ScreeningStore {
    private static let key = "screeningRecord.v1"

    static func save(_ record: ScreeningRecord) {
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> ScreeningRecord? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(ScreeningRecord.self, from: data)
        else { return nil }
        return record
    }

    static var hasCompleted: Bool { UserDefaults.standard.data(forKey: key) != nil }

    /// Wipe the saved screening (the tracker's "Ulangi skrining" / start-over).
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
