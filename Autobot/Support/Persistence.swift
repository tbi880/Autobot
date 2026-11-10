// Persistence.swift
// Codable values kept in UserDefaults as JSON: what the finders learned, the regeneration log, the engine
// health state, saved places.

import Foundation

extension UserDefaults {
    /// The value saved under `key` by setCodable(_:forKey:); nil if there is none or it no longer decodes.
    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Saves `value` under `key` as JSON. What is saved there stays as it is if `value` can't be encoded.
    func setCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, forKey: key) }
    }
}
