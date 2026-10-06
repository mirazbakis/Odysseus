//
//  ODKeychain.swift
//  Odysseus
//
//  Small generic-password Keychain wrapper (this device only).
//

import Foundation
import Security

enum ODKeychain {
	private static let _service = "com.mirazbakis.Odysseus"

	static func set(_ data: Data?, for key: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: _service,
			kSecAttrAccount as String: key
		]
		SecItemDelete(query as CFDictionary)

		guard let data else { return }
		var attributes = query
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		SecItemAdd(attributes as CFDictionary, nil)
	}

	static func data(for key: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: _service,
			kSecAttrAccount as String: key,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
		return item as? Data
	}

	static func setString(_ string: String?, for key: String) {
		set(string.flatMap { $0.data(using: .utf8) }, for: key)
	}

	static func string(for key: String) -> String? {
		data(for: key).flatMap { String(data: $0, encoding: .utf8) }
	}

	static func setCodable<T: Encodable>(_ value: T?, for key: String) {
		guard let value else { set(nil, for: key); return }
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		set(try? encoder.encode(value), for: key)
	}

	static func codable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
		guard let data = data(for: key) else { return nil }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try? decoder.decode(type, from: data)
	}
}
