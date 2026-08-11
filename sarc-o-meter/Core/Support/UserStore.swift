//  UserStore.swift
//
//  Persists the central `User` (UserDefaults, small JSON blob). Because a saved
//  user is only written once screening completes, a non-nil `load()` whose
//  `screening` is set is the app's "returning user → go to the tracker" signal.

import Foundation

enum UserStore {
    private static let key = "user.v1"

    static func save(_ user: User) {
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> User? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let user = try? JSONDecoder().decode(User.self, from: data)
        else { return nil }
        return user
    }

    /// Wipe the saved user (the tracker's "Ulangi skrining" / start-over).
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
