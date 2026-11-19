//
//  ODAnisette.swift
//  Odysseus
//
//  Anisette server handling, same approach as AltLoad: a built-in list
//  (Windows-ADI servers first, since Apple refuses most other remote
//  anisette), merged with SideStore's live list, health-checked before
//  sign-in, one anisette identity per server, and failover by Apple's
//  error code.
//

import Foundation
import SideSign

struct ODAnisetteServer: Codable, Hashable, Identifiable {
	let name: String
	let address: String
	var id: String { address }
}

@MainActor
final class ODAnisetteServers: ObservableObject {
	static let shared = ODAnisetteServers()

	static let listURL = URL(string: "https://servers.sidestore.io/servers.json")!
	/// Stored as the choice when Odysseus should pick a working server itself.
	static let automatic = "auto"
	static let choiceKey = "Odysseus.anisette.choice"
	/// The server the current Apple ID session was made with.
	static let sessionServerKey = "Odysseus.anisette.sessionServer"

	static let builtIn: [ODAnisetteServer] = [
		ODAnisetteServer(name: "jkcoxson (Windows ADI)", address: "https://ani.jkcoxson.com"),
		ODAnisetteServer(name: "jkcoxson (Mac ADI)", address: "https://mac-ani.jkcoxson.com"),
		ODAnisetteServer(name: "SideStore (Windows ADI)", address: "https://win.ani.sidestore.io"),
		ODAnisetteServer(name: "SideStore", address: "https://ani.sidestore.io"),
		ODAnisetteServer(name: "SideStore (.app)", address: "https://ani.sidestore.app"),
		ODAnisetteServer(name: "SideStore (.zip)", address: "https://ani.sidestore.zip"),
		ODAnisetteServer(name: "SideStore (.xyz)", address: "https://ani.846969.xyz"),
		ODAnisetteServer(name: "nythepegasus", address: "https://ani.npeg.us"),
		ODAnisetteServer(name: "WE. Studio", address: "https://anisette.wedotstud.io"),
		ODAnisetteServer(name: "crystall1nedev", address: "https://anisette.crystall1ne.dev"),
	]

	@Published private(set) var servers: [ODAnisetteServer] = ODAnisetteServers.builtIn
	@Published private(set) var isLoading = false

	var choice: String {
		get { UserDefaults.standard.string(forKey: Self.choiceKey) ?? Self.automatic }
		set { UserDefaults.standard.set(newValue, forKey: Self.choiceKey) }
	}

	private struct Listing: Decodable {
		let servers: [ODAnisetteServer]
	}

	/// Merges the live list into the built-in one. HTTPS only, since sign-in headers pass through it.
	func refresh() async {
		guard !isLoading else { return }
		isLoading = true
		defer { isLoading = false }
		do {
			let (data, _) = try await URLSession.shared.data(from: Self.listURL)
			let live = try JSONDecoder().decode(Listing.self, from: data).servers
				.filter { $0.address.lowercased().hasPrefix("https://") }
			var merged = Self.builtIn
			for server in live where !merged.contains(where: { $0.address == server.address }) {
				merged.append(server)
			}
			servers = merged
		} catch {
			servers = Self.builtIn
		}
	}

	func name(for address: String) -> String {
		if address == Self.automatic { return .localized("Automatic") }
		return servers.first { $0.address == address }?.name ?? URL(string: address)?.host ?? address
	}

	/// The servers to sign in with, best first. A server the user picked goes
	/// first; servers that don't answer are dropped.
	func signInList() async -> [URL] {
		let preferred = choice
		var order = servers.map(\.address)
		let pinned = preferred != Self.automatic && !preferred.isEmpty
		if pinned {
			order.removeAll { $0 == preferred }
			order.insert(preferred, at: 0)
		}
		let candidates = Array(order.prefix(8))
		let alive = await withTaskGroup(of: (String, Bool).self) { group in
			for address in candidates {
				group.addTask { (address, await Self.isAlive(address)) }
			}
			var results: [String: Bool] = [:]
			for await (address, ok) in group { results[address] = ok }
			return results
		}
		var picked = candidates.filter { alive[$0] == true }
		// A server the user chose is always tried, even if the check missed it.
		if pinned, !picked.contains(preferred) { picked.insert(preferred, at: 0) }
		if picked.isEmpty { picked = Array(candidates.prefix(3)) }
		return picked.prefix(ODSignInFailure.maxServersPerTry).compactMap { URL(string: $0) }
	}

	/// Quick check that a v3 server answers with its client info.
	nonisolated static func isAlive(_ address: String) async -> Bool {
		guard let url = URL(string: address.trimmingCharacters(in: .whitespaces) + "/v3/client_info") else { return false }
		let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
		guard let (data, response) = try? await URLSession.shared.data(for: request),
			  (response as? HTTPURLResponse)?.statusCode == 200,
			  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
		return json["client_info"] is String
	}

	// MARK: Per-server identity
	/// Each server provisions its own anisette identity, so each gets its own
	/// machine identifier and ADI blob.
	nonisolated static func identifier(for server: URL) -> UUID {
		let key = "Odysseus.anisette.id.\(server.host ?? server.absoluteString)"
		if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
			return uuid
		}
		let uuid = UUID()
		UserDefaults.standard.set(uuid.uuidString, forKey: key)
		return uuid
	}

	nonisolated static func blobKey(for server: URL) -> String {
		"appleid.anisetteBlob.\(server.host ?? server.absoluteString)"
	}

	/// Fresh anisette data from one server, keeping its provisioning.
	nonisolated static func fetch(from server: URL) async throws -> AnisetteData {
		let blobKey = blobKey(for: server)
		let (data, newBlob) = try await AnisetteDataManager.shared.fetchAnisetteData(
			mode: .remote(server: server),
			identifier: identifier(for: server),
			existingAdiBlob: ODKeychain.data(for: blobKey),
			headers: nil,
			onError: nil
		)
		if let newBlob {
			ODKeychain.set(newBlob, for: blobKey)
		}
		return data
	}

	/// Forgets every anisette identity, so the next sign-in starts clean.
	/// Useful after Apple rejects one.
	nonisolated static func resetProvisioning() {
		let defaults = UserDefaults.standard
		for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("Odysseus.anisette.id.") {
			defaults.removeObject(forKey: key)
		}
		for server in builtIn {
			if let url = URL(string: server.address) {
				ODKeychain.set(nil, for: blobKey(for: url))
			}
		}
		if let session = defaults.string(forKey: sessionServerKey), let url = URL(string: session) {
			ODKeychain.set(nil, for: blobKey(for: url))
		}
		AnisetteDataManager.shared.clearCache()
	}
}

// MARK: - Failure classes
/// What a failed sign-in means, by Apple's error code (as AltLoad does it).
enum ODSignInFailure: Equatable {
	/// -22406 / -20101 / -20970: a wrong password, or Apple refusing the anisette data.
	case passwordOrAnisette
	case locked
	case rateLimited
	/// The anisette server or Apple refusing its data; another server may work.
	case anisette
	case other

	static let maxServersPerTry = 2
	static let rejectionsBeforePause = 2
	static let pauseSeconds: TimeInterval = 15 * 60

	static func classify(_ error: Error) -> ODSignInFailure {
		if let portal = error as? DeveloperPortalError {
			switch portal {
			case .tooManyAttempts: return .rateLimited
			case .invalidAnisetteData: return .anisette
			case .incorrectCredentials: return .passwordOrAnisette
			case .incorrectVerificationCode, .userCancelled, .requiresTwoFactorAuthentication,
				 .invalid2FAResponse, .appSpecificPasswordRequired, .accountRepairRequired:
				return .other
			default: break
			}
		}
		if error is ODAppleIDError || error is CancellationError { return .other }

		var code: Int?
		if case ServerError.underlyingError(let c, _) = error { code = c }
		let message = "\(error) \(error.localizedDescription)".lowercased()
		if message.contains("too many requests") { return .rateLimited }
		if code == nil, let range = message.range(of: #"\(-\d{4,5}\)"#, options: .regularExpression) {
			code = Int(message[range].dropFirst().dropLast())
		}
		if let code {
			switch code {
			case -22406, -20101, -20970: return .passwordOrAnisette
			case -20209: return .locked
			case -45061, -45054, -80045, -22410, -22411: return .anisette
			default:
				if message.contains("locked") || message.contains("disabled") { return .locked }
				if message.contains("incorrect") { return .passwordOrAnisette }
				return .other
			}
		}
		let userSide = ["incorrect", "password", "2fa", "two-factor", "verification code", "cancel", "abort", "locked", "disabled"]
		if userSide.contains(where: message.contains) { return .other }
		if error is URLError { return .anisette }
		let anisette = ["anisette", "provision", "client info", "client_info", "websocket", "timed out",
						"connection", "dns", "certificate", "status code 5", "502", "503", "504"]
		return anisette.contains(where: message.contains) ? .anisette : .other
	}
}

// MARK: - Sign-in pause
/// After repeated refusals Odysseus pauses sign-ins for that Apple ID so it
/// doesn't get locked.
enum ODSignInPause {
	private static let key = "Odysseus.signInPause"

	private struct State: Codable {
		var appleID: String
		var rejections: Int
		var until: Date?
	}

	private static func load(_ appleID: String) -> State? {
		guard let data = UserDefaults.standard.data(forKey: key),
			  let state = try? JSONDecoder().decode(State.self, from: data),
			  state.appleID == appleID.lowercased() else { return nil }
		return state
	}

	/// Minutes left in a pause, or nil.
	static func minutesLeft(_ appleID: String) -> Int? {
		guard let until = load(appleID)?.until, until > Date() else { return nil }
		return Int((until.timeIntervalSinceNow / 60).rounded(.up))
	}

	static func recordRejection(_ appleID: String, pauseNow: Bool) {
		let rejections = (load(appleID)?.rejections ?? 0) + 1
		let pause = pauseNow || rejections >= ODSignInFailure.rejectionsBeforePause
		let state = State(appleID: appleID.lowercased(), rejections: rejections, until: pause ? Date().addingTimeInterval(ODSignInFailure.pauseSeconds) : nil)
		if let data = try? JSONEncoder().encode(state) {
			UserDefaults.standard.set(data, forKey: key)
		}
	}

	static func clear() {
		UserDefaults.standard.removeObject(forKey: key)
	}
}
