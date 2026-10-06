//
//  ODCatalog.swift
//  Odysseus
//
//  Turns every loaded source into one App Store-style catalog.
//  Apps with the same bundle ID are combined ("available from N
//  sources"), keeping the newest version as the main listing.
//

import Foundation
import SwiftUI
import AltSourceKit

struct ODCatalogOffer: Identifiable, Hashable {
	let sourceID: String
	let sourceName: String
	let repository: ASRepository
	let app: ASRepository.App

	var id: String { "\(sourceID)|\(app.currentUniqueId)" }

	static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
	func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ODCatalogApp: Identifiable, Hashable {
	let id: String
	/// Newest version first.
	let offers: [ODCatalogOffer]
	let firstSeen: Date

	var primary: ODCatalogOffer { offers[0] }
	var app: ASRepository.App { primary.app }
	var repository: ASRepository { primary.repository }
	var sourceCount: Int { Set(offers.map(\.sourceID)).count }

	var updatedDate: Date? { app.currentDate?.date }
	var category: String? { app.category?.lowercased() }

	static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.offers == rhs.offers }
	func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ODCatalogSource: Identifiable {
	let id: String
	let name: String
	let iconURL: URL?
	let tint: Color?
	let apps: [ODCatalogApp]
}

struct ODCatalog {
	var apps: [ODCatalogApp] = []
	var sources: [ODCatalogSource] = []

	var isEmpty: Bool { apps.isEmpty }

	// MARK: Build
	static func build(
		from loaded: [(source: AltSource, repository: ASRepository)],
		combineDuplicates: Bool,
		hiddenSourceIDs: Set<String>
	) -> ODCatalog {
		let visible = loaded.filter { !hiddenSourceIDs.contains($0.source.identifier ?? "") }
		var groups: [String: [ODCatalogOffer]] = [:]
		var order: [String] = []

		for (source, repository) in visible {
			let sourceID = source.identifier ?? source.sourceURL?.absoluteString ?? UUID().uuidString
			let sourceName = repository.name ?? source.name ?? .localized("Source")
			for app in repository.apps where app.currentDownloadUrl != nil {
				let offer = ODCatalogOffer(sourceID: sourceID, sourceName: sourceName, repository: repository, app: app)
				let key: String
				if combineDuplicates, let bundle = app.id?.lowercased(), !bundle.isEmpty {
					key = bundle
				} else {
					key = offer.id
				}
				if groups[key] == nil { order.append(key) }
				groups[key, default: []].append(offer)
			}
		}

		let firstSeen = ODFirstSeen.update(with: order)

		let apps: [ODCatalogApp] = order.compactMap { key in
			guard let offers = groups[key], !offers.isEmpty else { return nil }
			let sorted = offers.sorted { lhs, rhs in
				(lhs.app.currentDate?.date ?? .distantPast) > (rhs.app.currentDate?.date ?? .distantPast)
			}
			return ODCatalogApp(id: key, offers: sorted, firstSeen: firstSeen[key] ?? .distantPast)
		}

		let byKey = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
		let sources: [ODCatalogSource] = visible.map { source, repository in
			let sourceID = source.identifier ?? source.sourceURL?.absoluteString ?? ""
			let sourceApps: [ODCatalogApp] = repository.apps.compactMap { app in
				guard app.currentDownloadUrl != nil else { return nil }
				let key: String
				if combineDuplicates, let bundle = app.id?.lowercased(), !bundle.isEmpty {
					key = bundle
				} else {
					key = "\(sourceID)|\(app.currentUniqueId)"
				}
				return byKey[key]
			}
			return ODCatalogSource(
				id: sourceID,
				name: repository.name ?? source.name ?? .localized("Source"),
				iconURL: repository.currentIconURL ?? source.iconURL,
				tint: repository.tintColor,
				apps: _unique(sourceApps)
			)
		}
		.filter { !$0.apps.isEmpty }

		return ODCatalog(apps: apps, sources: sources)
	}

	private static func _unique(_ apps: [ODCatalogApp]) -> [ODCatalogApp] {
		var seen = Set<String>()
		return apps.filter { seen.insert($0.id).inserted }
	}

	// MARK: Rows
	/// Apps flagged as featured by their source, then fall back to
	/// the newest app from each source.
	var featured: [ODCatalogApp] {
		var result: [ODCatalogApp] = []
		var seen = Set<String>()
		for source in sources {
			let featuredIDs = source.apps.first?.offers.first(where: { $0.sourceID == source.id })?.repository.featuredApps ?? []
			let ids = Set(featuredIDs.compactMap { $0 })
			let picks = source.apps.filter { app in
				app.offers.contains { offer in
					guard offer.sourceID == source.id, let id = offer.app.id else { return false }
					return ids.contains(id)
				}
			}
			for app in (picks.isEmpty ? Array(source.apps.prefix(1)) : Array(picks.prefix(2))) where seen.insert(app.id).inserted {
				result.append(app)
			}
		}
		return Array(result.prefix(10))
	}

	var newAndUpdated: [ODCatalogApp] {
		apps
			.filter { $0.updatedDate != nil }
			.sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }
			.prefix(20)
			.map { $0 }
	}

	var recentlyAdded: [ODCatalogApp] {
		let recent = apps
			.filter { $0.firstSeen > Date().addingTimeInterval(-14 * 86_400) }
			.sorted { $0.firstSeen > $1.firstSeen }
		return Array(recent.prefix(20))
	}

	var categories: [ODCategory] {
		let present = Set(apps.compactMap(\.category))
		var result = ODCategory.known.filter { present.contains($0.id) }
		for other in present.subtracting(ODCategory.known.map(\.id)).sorted() {
			result.append(ODCategory(id: other, name: other.capitalized, icon: "square.grid.2x2"))
		}
		return result
	}

	func apps(in category: ODCategory) -> [ODCatalogApp] {
		apps.filter { $0.category == category.id }
			.sorted { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending }
	}

	func search(_ text: String) -> [ODCatalogApp] {
		let query = text.trimmingCharacters(in: .whitespaces)
		guard !query.isEmpty else { return [] }
		return apps.filter { app in
			app.app.currentName.localizedCaseInsensitiveContains(query)
				|| (app.app.developer?.localizedCaseInsensitiveContains(query) ?? false)
				|| (app.app.id?.localizedCaseInsensitiveContains(query) ?? false)
				|| (app.app.currentDescription?.localizedCaseInsensitiveContains(query) ?? false)
		}
		.sorted { lhs, rhs in
			let l = lhs.app.currentName.lowercased().hasPrefix(query.lowercased())
			let r = rhs.app.currentName.lowercased().hasPrefix(query.lowercased())
			if l != r { return l }
			return lhs.app.currentName.localizedCaseInsensitiveCompare(rhs.app.currentName) == .orderedAscending
		}
	}
}

// MARK: - Categories (AltStore `category` values)
struct ODCategory: Identifiable, Hashable {
	let id: String
	let name: String
	let icon: String

	static let known: [ODCategory] = [
		.init(id: "games", name: .localized("Games"), icon: "gamecontroller.fill"),
		.init(id: "entertainment", name: .localized("Entertainment"), icon: "tv.fill"),
		.init(id: "utilities", name: .localized("Utilities"), icon: "wrench.and.screwdriver.fill"),
		.init(id: "developer", name: .localized("Developer"), icon: "hammer.fill"),
		.init(id: "photo-video", name: .localized("Photo & Video"), icon: "camera.fill"),
		.init(id: "social", name: .localized("Social"), icon: "bubble.left.and.bubble.right.fill"),
		.init(id: "lifestyle", name: .localized("Lifestyle"), icon: "leaf.fill"),
		.init(id: "other", name: .localized("Other"), icon: "square.grid.2x2.fill")
	]
}

// MARK: - First seen
/// Remembers when each app first showed up, for "Recently Added".
enum ODFirstSeen {
	private static let _key = "Odysseus.firstSeen"
	private static let _createdKey = "Odysseus.firstSeenCreated"

	static func update(with keys: [String]) -> [String: Date] {
		let defaults = UserDefaults.standard
		if defaults.object(forKey: _createdKey) == nil {
			defaults.set(Date().timeIntervalSince1970, forKey: _createdKey)
		}
		// Everything loaded in the first 10 minutes counts as "already there".
		let isFirstRun = Date().timeIntervalSince1970 - defaults.double(forKey: _createdKey) < 600
		var stored = (defaults.dictionary(forKey: _key) as? [String: Double]) ?? [:]
		let now = Date().timeIntervalSince1970
		var changed = false

		for key in keys where stored[key] == nil {
			// On the very first load nothing is "recently added".
			stored[key] = isFirstRun ? 0 : now
			changed = true
		}

		if changed || isFirstRun {
			defaults.set(stored, forKey: _key)
		}
		return stored.mapValues { Date(timeIntervalSince1970: $0) }
	}
}
