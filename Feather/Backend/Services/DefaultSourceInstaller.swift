//
//  DefaultSourceInstaller.swift
//  Odysseus
//
//  Reads Resources/DefaultSources.json. The bundled list is added once
//  (first launch); the optional `remoteList` is fetched on every launch
//  and any sources that aren't in the library yet are added.
//
//  Placeholders ("ADD_HERESOURCE", "ADD_HERE_REMOTE_LIST_URL") and
//  anything that isn't an http(s) URL are ignored.
//

import Foundation
import CoreData
import OSLog

enum DefaultSourceInstaller {
	private static let _didInstallKey = "Odysseus.didInstallDefaultSources"

	// MARK: Bundled config
	struct Config: Decodable {
		var remoteList: String?
		var sources: [String]?
		var featured: [String]?
	}

	static let config: Config = {
		guard
			let url = Bundle.main.url(forResource: "DefaultSources", withExtension: "json"),
			let data = try? Data(contentsOf: url),
			let config = try? JSONDecoder().decode(Config.self, from: data)
		else {
			return Config(remoteList: nil, sources: [], featured: [])
		}
		return config
	}()

	static func validURL(_ string: String?) -> URL? {
		guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !string.isEmpty,
			  !string.uppercased().contains("ADD_HERE"),
			  let url = URL(string: string),
			  let scheme = url.scheme?.lowercased(),
			  scheme == "https" || scheme == "http",
			  url.host != nil
		else {
			return nil
		}
		return url
	}

	static var bundledSourceURLs: [URL] { (config.sources ?? []).compactMap(validURL) }
	static var featuredSourceURLs: [URL] { (config.featured ?? []).compactMap(validURL) }
	static var remoteListURL: URL? { validURL(config.remoteList) }

	// MARK: Install
	@discardableResult
	@MainActor
	static func installIfNeeded() -> Int {
		guard UserDefaults.standard.bool(forKey: _didInstallKey) == false else {
			return 0
		}

		let insertedCount = _install(bundledSourceURLs)
		UserDefaults.standard.set(true, forKey: _didInstallKey)
		Logger.misc.info("Installed \(insertedCount) default sources")
		return insertedCount
	}

	@MainActor
	static func updateFromRemote() async throws -> Int {
		guard let remote = remoteListURL else { return 0 }
		let urls = try await _fetchRemoteSourceURLs(from: remote)
		let insertedCount = _install(urls)
		Logger.misc.info("Installed \(insertedCount) remote sources")
		return insertedCount
	}

	@MainActor
	private static func _install(_ urls: [URL]) -> Int {
		let storage = Storage.shared
		let existingURLs = Set(storage.getSources().compactMap { $0.sourceURL?.absoluteString })
		var insertedCount = 0

		for url in urls {
			guard
				!storage.sourceExists(url.absoluteString),
				!existingURLs.contains(url.absoluteString)
			else {
				continue
			}

			storage.addSource(
				url,
				name: _displayName(for: url),
				identifier: url.absoluteString,
				deferSave: true
			) { error in
				if let error {
					Logger.misc.error("Failed to add default source \(url.absoluteString): \(error.localizedDescription)")
				} else {
					insertedCount += 1
				}
			}
		}

		do {
			if storage.context.hasChanges {
				try storage.context.save()
			}
		} catch {
			Logger.misc.error("Failed to save sources: \(error.localizedDescription)")
		}

		return insertedCount
	}

	/// Accepts a JSON array of strings, a JSON object with a "sources"
	/// array, or plain text with one URL per line.
	private static func _fetchRemoteSourceURLs(from remote: URL) async throws -> [URL] {
		let (data, response) = try await URLSession.shared.data(from: remote)

		guard
			let httpResponse = response as? HTTPURLResponse,
			(200..<300).contains(httpResponse.statusCode)
		else {
			throw DefaultSourceInstallerError.invalidResponse
		}

		var candidates: [String] = []
		if let array = try? JSONDecoder().decode([String].self, from: data) {
			candidates = array
		} else if let object = try? JSONDecoder().decode(Config.self, from: data), let list = object.sources {
			candidates = list
		} else if let string = String(data: data, encoding: .utf8) {
			candidates = string
				.split(whereSeparator: \.isNewline)
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.hasPrefix("#") }
		} else {
			throw DefaultSourceInstallerError.invalidData
		}

		var seen = Set<String>()
		return candidates.compactMap { candidate in
			guard let url = validURL(candidate), seen.insert(url.absoluteString).inserted else { return nil }
			return url
		}
	}

	private static func _displayName(for url: URL) -> String {
		guard let host = url.host?.replacingOccurrences(of: "www.", with: "") else {
			return url.absoluteString
		}
		return host
	}
}

enum DefaultSourceInstallerError: LocalizedError {
	case invalidResponse
	case invalidData

	var errorDescription: String? {
		switch self {
		case .invalidResponse:
			return .localized("The source list could not be downloaded.")
		case .invalidData:
			return .localized("The source list is not valid.")
		}
	}
}
