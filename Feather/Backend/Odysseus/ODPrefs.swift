//
//  ODPrefs.swift
//  Odysseus
//
//  UserDefaults keys for Odysseus settings, in one place.
//

import Foundation

enum ODPrefs {
	// Certificates & OCSP
	static let ocspFrequencyHours = "Odysseus.ocsp.frequencyHours"        // Int, 0 = only manual
	static let ocspActionOnRevoked = "Odysseus.ocsp.actionOnRevoked"      // Int, RevokedAction
	static let ocspNotifyOnChange = "Odysseus.ocsp.notifyOnChange"        // Bool
	static let expiryReminders = "Odysseus.expiryReminders"               // Bool
	static let expiryWarningDays = "Odysseus.expiryWarningDays"           // Int
	static let defaultCertificate = "feather.selectedCert"                // Int (Feather key)

	// Signing
	static let signingIdentity = "Odysseus.signingIdentity"               // Int, SigningIdentityKind
	static let bundleIDPrefix = "Odysseus.bundleIDPrefix"                 // String
	static let bundleIDSuffix = "Odysseus.bundleIDSuffix"                 // String
	static let appleIDAppendTeamID = "Odysseus.appleID.appendTeamID"      // Bool
	static let appleIDRemoveExtensions = "Odysseus.appleID.removeExtensions" // Bool

	// Installing
	static let installationMethod = "Feather.installationMethod"          // Int, 0 server, 1 pairing
	static let customPlistServer = "Odysseus.customPlistServer"           // String
	static let autoDeleteIPAs = "Odysseus.autoDeleteIPAs"                 // Bool

	// Sources & Discover
	static let sourceAutoRefreshHours = "Odysseus.sources.autoRefreshHours" // Int, 0 = off
	static let sourcesLastRefresh = "Odysseus.sources.lastRefresh"        // Double
	static let combineDuplicates = "Odysseus.discover.combineDuplicates"  // Bool
	static let discoverRowOrder = "Odysseus.discover.rowOrder"            // String (comma separated)
	static let discoverHiddenSources = "Odysseus.discover.hiddenSources"  // String (newline separated ids)

	// Appearance
	static let tintColor = "Feather.userTintColor"
	static let interfaceStyle = "Feather.userInterfaceStyle"

	static func registerDefaults() {
		UserDefaults.standard.register(defaults: [
			ocspFrequencyHours: 24,
			ocspActionOnRevoked: RevokedAction.warn.rawValue,
			ocspNotifyOnChange: true,
			expiryReminders: true,
			expiryWarningDays: 3,
			signingIdentity: SigningIdentityKind.certificate.rawValue,
			appleIDAppendTeamID: true,
			appleIDRemoveExtensions: true,
			autoDeleteIPAs: false,
			sourceAutoRefreshHours: 6,
			combineDuplicates: true,
			discoverRowOrder: DiscoverRow.defaultOrder.map(\.rawValue).joined(separator: ","),
			tintColor: ODTheme.moonlightHex,
			interfaceStyle: 2 // dark
		])
	}

	// MARK: Enums
	enum RevokedAction: Int, CaseIterable, Identifiable {
		case warn = 0
		case block = 1
		case allow = 2

		var id: Int { rawValue }

		var title: String {
			switch self {
			case .warn: return .localized("Warn Me")
			case .block: return .localized("Block Signing")
			case .allow: return .localized("Allow")
			}
		}
	}

	enum SigningIdentityKind: Int, CaseIterable, Identifiable {
		case certificate = 0
		case appleID = 1

		var id: Int { rawValue }

		var title: String {
			switch self {
			case .certificate: return .localized("Imported Certificate")
			case .appleID: return .localized("Apple ID")
			}
		}
	}

	enum DiscoverRow: String, CaseIterable, Identifiable {
		case featured
		case newAndUpdated
		case recentlyAdded
		case categories
		case sources

		var id: String { rawValue }

		static let defaultOrder: [DiscoverRow] = [.featured, .newAndUpdated, .recentlyAdded, .categories, .sources]

		var title: String {
			switch self {
			case .featured: return .localized("Featured")
			case .newAndUpdated: return .localized("New & Updated")
			case .recentlyAdded: return .localized("Recently Added")
			case .categories: return .localized("Categories")
			case .sources: return .localized("From Your Sources")
			}
		}
	}

	// MARK: Accessors
	static var revokedAction: RevokedAction {
		RevokedAction(rawValue: UserDefaults.standard.integer(forKey: ocspActionOnRevoked)) ?? .warn
	}

	static var signingIdentityKind: SigningIdentityKind {
		SigningIdentityKind(rawValue: UserDefaults.standard.integer(forKey: signingIdentity)) ?? .certificate
	}

	static var discoverOrder: [DiscoverRow] {
		let stored = (UserDefaults.standard.string(forKey: discoverRowOrder) ?? "")
			.split(separator: ",")
			.compactMap { DiscoverRow(rawValue: String($0)) }
		var order = stored
		for row in DiscoverRow.defaultOrder where !order.contains(row) {
			order.append(row)
		}
		return order
	}

	static func setDiscoverOrder(_ rows: [DiscoverRow]) {
		UserDefaults.standard.set(rows.map(\.rawValue).joined(separator: ","), forKey: discoverRowOrder)
	}

	static var hiddenSourceIDs: Set<String> {
		get {
			Set((UserDefaults.standard.string(forKey: discoverHiddenSources) ?? "")
				.split(separator: "\n")
				.map(String.init))
		}
		set {
			UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: discoverHiddenSources)
		}
	}

	/// Applies the bundle ID prefix/suffix settings.
	static func adjustedBundleID(_ identifier: String) -> String {
		let prefix = (UserDefaults.standard.string(forKey: bundleIDPrefix) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let suffix = (UserDefaults.standard.string(forKey: bundleIDSuffix) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		var result = identifier
		if !prefix.isEmpty {
			result = prefix.hasSuffix(".") ? prefix + result : prefix + "." + result
		}
		if !suffix.isEmpty {
			result = suffix.hasPrefix(".") ? result + suffix : result + "." + suffix
		}
		return result
	}
}
