//
//  ODAppleIDManager.swift
//  Odysseus
//
//  Sign and install apps with your own (free) Apple ID, using SideSign
//  from Catalyst/SideStore (AGPL-3.0) for the Apple Developer APIs.
//
//  What happens:
//    1. Sign in with Apple ID + password (+ 2FA). Anisette data comes
//       from an anisette server, like SideStore.
//    2. Odysseus makes its own Apple Development certificate on your
//       team. The private key is made on this device and never leaves
//       it, unless you export the .p12 yourself.
//    3. For each app: register this device's UDID, register an App ID
//       for the bundle ID, download a 7-day development profile, then
//       sign with zsign and install as usual.
//
//  Free accounts: profiles last 7 days, at most 3 apps signed at a
//  time, 10 new App IDs per 7 days. Needs proper testing on device.
//

import Foundation
import SwiftUI
import UIKit
import SideSign
import NimbleExtensions
import OSLog

// MARK: - Stored models
struct ODAppleIDCertificateInfo: Codable, Equatable {
	var serial: String
	var name: String
	var machineName: String?
	var expiration: Date?
	var der: Data
}

struct ODAppleIDAccountInfo: Codable, Equatable {
	var appleID: String
	var firstName: String
	var lastName: String
	var teamID: String
	var teamName: String
	var teamIsFree: Bool

	var displayName: String {
		let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
		return name.isEmpty ? appleID : name
	}
}

struct ODAppleIDSigningMaterial {
	let p12URL: URL
	let p12Password: String
	let provisionURL: URL
	let bundleIdentifier: String
	let expiration: Date
	let teamID: String
}

enum ODAppleIDError: LocalizedError {
	case notSignedIn
	case sessionExpired
	case missingUDID
	case tooManyCertificates([X509Certificate])
	case noCertificate
	case appIDLimit(String)
	case cancelled

	var errorDescription: String? {
		switch self {
		case .notSignedIn:
			return .localized("Sign in with your Apple ID in Settings → Apple ID first.")
		case .sessionExpired:
			return .localized("Your Apple ID session expired. Sign in again in Settings → Apple ID.")
		case .missingUDID:
			return .localized("Odysseus needs this device's UDID to make a profile. Import a pairing file (it includes the UDID) or enter the UDID in Settings → Apple ID.")
		case .tooManyCertificates:
			return .localized("Your Apple ID already has the maximum number of development certificates. Revoke one in Settings → Apple ID → Certificates, then try again.")
		case .noCertificate:
			return .localized("There's no Apple ID certificate yet.")
		case .appIDLimit(let cause):
			return .localized("Free Apple IDs can only make 10 App IDs every 7 days. %@", arguments: cause)
		case .cancelled:
			return .localized("Cancelled.")
		}
	}
}

// MARK: - Manager
@MainActor
final class ODAppleIDManager: ObservableObject {
	static let shared = ODAppleIDManager()

	// Keychain keys
	private enum Key {
		static let authSession = "appleid.authSession"
		static let password = "appleid.password"
		static let account = "appleid.account"
		static let certificate = "appleid.certificate"
		static let p12 = "appleid.p12"
		static let p12Password = "appleid.p12Password"
		static let anisetteBlob = "appleid.anisetteBlob"
	}

	static let anisetteServersKey = "Odysseus.anisetteServers"
	static let rememberPasswordKey = "Odysseus.appleID.rememberPassword"
	static let manualUDIDKey = "Odysseus.deviceUDID"
	static let anisetteIdentifierKey = "Odysseus.anisetteIdentifier"
	static let defaultAnisetteServer = "https://ani.sidestore.io"
	static let xcodeVersion = "26.0 (26A242)"

	@Published private(set) var account: ODAppleIDAccountInfo?
	@Published private(set) var certificate: ODAppleIDCertificateInfo?
	@Published private(set) var availableTeams: [Team] = []
	@Published var twoFactorPrompt: TwoFactorRequest?
	@Published private(set) var isWorking = false
	@Published var lastError: String?

	private var _twoFactorContinuation: CheckedContinuation<TwoFactorResponse, Error>?
	private var _authSession: AuthSession?
	private var _team: Team?
	private let _portal = DeveloperPortal.shared

	var isSignedIn: Bool { account != nil && _authSession != nil }

	private init() {
		_authSession = ODKeychain.codable(AuthSession.self, for: Key.authSession)
		account = ODKeychain.codable(ODAppleIDAccountInfo.self, for: Key.account)
		certificate = ODKeychain.codable(ODAppleIDCertificateInfo.self, for: Key.certificate)
		if let account {
			_team = Team(
				identifier: account.teamID,
				name: account.teamName,
				type: account.teamIsFree ? .free : .individual,
				account: _authSession?.account
			)
		}
	}

	// MARK: Anisette
	var anisetteServers: [URL] {
		let stored = UserDefaults.standard.string(forKey: Self.anisetteServersKey) ?? Self.defaultAnisetteServer
		let urls = stored
			.split(whereSeparator: { $0 == "\n" || $0 == "," })
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.compactMap { URL(string: $0) }
		return urls.isEmpty ? [URL(string: Self.defaultAnisetteServer)!] : urls
	}

	private var _anisetteIdentifier: UUID {
		if let stored = UserDefaults.standard.string(forKey: Self.anisetteIdentifierKey), let uuid = UUID(uuidString: stored) {
			return uuid
		}
		let uuid = UUID()
		UserDefaults.standard.set(uuid.uuidString, forKey: Self.anisetteIdentifierKey)
		return uuid
	}

	private func _fetchAnisette() async throws -> AnisetteData {
		let existingBlob = ODKeychain.data(for: Key.anisetteBlob)
		let (data, newBlob) = try await AnisetteDataManager.shared.fetchAnisetteDataWithFailover(
			servers: anisetteServers,
			startIndex: 0,
			identifier: _anisetteIdentifier,
			existingAdiBlob: existingBlob,
			headers: nil,
			onError: nil,
			onSuccess: nil
		)
		if let newBlob {
			ODKeychain.set(newBlob, for: Key.anisetteBlob)
		}
		return data
	}

	// MARK: Device UDID
	/// The UDID from the pairing file, or the one entered by hand.
	var deviceUDID: String? {
		if let manual = UserDefaults.standard.string(forKey: Self.manualUDIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !manual.isEmpty {
			return manual
		}
		let pairing = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		guard
			let data = try? Data(contentsOf: pairing),
			let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
		else {
			return nil
		}
		return (plist["UDID"] as? String) ?? (plist["UniqueDeviceID"] as? String)
	}

	private var _deviceType: DeviceType {
		UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
	}

	// MARK: Sign in
	func signIn(appleID: String, password: String, rememberPassword: Bool) async throws {
		isWorking = true
		lastError = nil
		defer { isWorking = false }

		let anisette = try await _fetchAnisette()

		let verification: DeveloperPortal.VerificationHandler = { request in
			try await ODAppleIDManager.shared._askTwoFactor(request)
		}

		let authSession = try await _portal.authenticate(
			appleID: appleID,
			password: password,
			anisetteData: anisette,
			xcodeVersion: Self.xcodeVersion,
			machinePassword: nil,
			accountRepairHandler: DeveloperPortal.defaultAccountRepairHandler,
			verificationHandler: verification
		)

		let teams = try await _portal.fetchTeams(for: authSession.account, session: authSession.session)
		guard let team = teams.first(where: { $0.type == .free }) ?? teams.first else {
			throw DeveloperPortalError.noTeams
		}

		_authSession = authSession
		ODKeychain.setCodable(authSession, for: Key.authSession)
		UserDefaults.standard.set(rememberPassword, forKey: Self.rememberPasswordKey)
		ODKeychain.setString(rememberPassword ? password : nil, for: Key.password)

		availableTeams = teams
		_select(team: team, account: authSession.account)

		// Get the certificate ready now so the first install is quick.
		do {
			try await ensureCertificate()
		} catch {
			lastError = error.localizedDescription
		}
	}

	func select(team: Team) {
		guard let account = _authSession?.account else { return }
		// A different team means a different certificate.
		if team.identifier != _team?.identifier {
			_clearCertificate()
		}
		_select(team: team, account: account)
	}

	private func _select(team: Team, account: Account) {
		_team = team
		let info = ODAppleIDAccountInfo(
			appleID: account.appleID,
			firstName: account.firstName,
			lastName: account.lastName,
			teamID: team.identifier,
			teamName: team.name,
			teamIsFree: team.type == .free
		)
		self.account = info
		ODKeychain.setCodable(info, for: Key.account)
	}

	func signOut(keepCertificate: Bool = false) {
		_authSession = nil
		_team = nil
		account = nil
		availableTeams = []
		ODKeychain.set(nil, for: Key.authSession)
		ODKeychain.set(nil, for: Key.password)
		ODKeychain.set(nil, for: Key.account)
		if !keepCertificate {
			_clearCertificate()
		}
		AnisetteDataManager.shared.clearCache()
	}

	private func _clearCertificate() {
		certificate = nil
		ODKeychain.set(nil, for: Key.certificate)
		ODKeychain.set(nil, for: Key.p12)
		ODKeychain.set(nil, for: Key.p12Password)
		ODCertificateStatusStore.shared.removeValue(forKey: ODCertificateStatusStore.appleIDKey)
	}

	// MARK: 2FA
	private func _askTwoFactor(_ request: TwoFactorRequest) async throws -> TwoFactorResponse {
		// Pick the trusted device automatically the first time.
		if case .selectDeliveryMethod(let preferred, let phoneNumbers) = request {
			switch preferred {
			case .sms:
				if let phone = phoneNumbers.first { return .requestSMS(phoneID: phone.id) }
			case .voice:
				if let phone = phoneNumbers.first { return .requestVoice(phoneID: phone.id) }
			case .trustedDevice:
				break
			}
			return .requestTrustedDevice
		}
		return try await withCheckedThrowingContinuation { continuation in
			_twoFactorContinuation?.resume(throwing: ODAppleIDError.cancelled)
			_twoFactorContinuation = continuation
			twoFactorPrompt = request
			_presentTwoFactorAlert(request)
		}
	}

	/// A UIKit alert so it shows on top of whatever is on screen
	/// (sign-in sheet, signing flow, …).
	private func _presentTwoFactorAlert(_ request: TwoFactorRequest) {
		let message: String
		var phones: [TrustedPhoneNumber] = []
		switch request {
		case .trustedDevice:
			message = .localized("Enter the code shown on your other Apple device.")
		case .sms(let numbers, _, _):
			message = .localized("Enter the code sent by text message.")
			phones = numbers
		case .voice(let numbers, _, _):
			message = .localized("Enter the code from the phone call.")
			phones = numbers
		case .selectDeliveryMethod(_, let numbers):
			message = .localized("Enter the verification code.")
			phones = numbers
		}

		let alert = UIAlertController(
			title: .localized("Two-Factor Authentication"),
			message: [request.error, message].compactMap { $0 }.joined(separator: "\n\n"),
			preferredStyle: .alert
		)
		alert.addTextField { field in
			field.placeholder = .localized("6-digit code")
			field.keyboardType = .numberPad
			field.textContentType = .oneTimeCode
		}
		alert.addAction(UIAlertAction(title: .localized("Verify"), style: .default) { [weak alert] _ in
			let code = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
			ODAppleIDManager.shared.answerTwoFactor(.verificationCode(code))
		})
		if case .trustedDevice = request {} else {
			alert.addAction(UIAlertAction(title: .localized("Use Trusted Device"), style: .default) { _ in
				ODAppleIDManager.shared.answerTwoFactor(.requestTrustedDevice)
			})
		}
		for phone in phones.prefix(2) {
			alert.addAction(UIAlertAction(title: .localized("Text %@", arguments: phone.number), style: .default) { _ in
				ODAppleIDManager.shared.answerTwoFactor(.requestSMS(phoneID: phone.id))
			})
		}
		alert.addAction(UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in
			ODAppleIDManager.shared.cancelTwoFactor()
		})

		UIApplication.topViewController()?.present(alert, animated: true)
	}

	func answerTwoFactor(_ response: TwoFactorResponse) {
		twoFactorPrompt = nil
		let continuation = _twoFactorContinuation
		_twoFactorContinuation = nil
		continuation?.resume(returning: response)
	}

	func cancelTwoFactor() {
		twoFactorPrompt = nil
		let continuation = _twoFactorContinuation
		_twoFactorContinuation = nil
		continuation?.resume(throwing: ODAppleIDError.cancelled)
	}

	// MARK: Session
	private func _freshSession() async throws -> (Session, Team) {
		guard var authSession = _authSession, let team = _team else {
			throw ODAppleIDError.notSignedIn
		}

		if authSession.session.isExpired {
			guard let password = ODKeychain.string(for: Key.password) else {
				throw ODAppleIDError.sessionExpired
			}
			try await signIn(appleID: authSession.account.appleID, password: password, rememberPassword: true)
			guard let renewed = _authSession, let renewedTeam = _team else { throw ODAppleIDError.sessionExpired }
			authSession = renewed
			return (renewed.session, renewedTeam)
		}

		var session = authSession.session
		session.anisetteData = try await _fetchAnisette()
		return (session, team)
	}

	/// Runs a portal call and re-authenticates once if the token was rejected.
	private func _withSession<T>(_ body: (Session, Team) async throws -> T) async throws -> T {
		let (session, team) = try await _freshSession()
		do {
			return try await body(session, team)
		} catch DeveloperPortalError.incorrectCredentials {
			guard let password = ODKeychain.string(for: Key.password), let appleID = account?.appleID else {
				throw ODAppleIDError.sessionExpired
			}
			try await signIn(appleID: appleID, password: password, rememberPassword: true)
			let (newSession, newTeam) = try await _freshSession()
			return try await body(newSession, newTeam)
		}
	}

	// MARK: Certificate
	/// Makes sure Odysseus has a development certificate (with its
	/// private key) that is still on the Apple ID's team.
	func ensureCertificate() async throws {
		try await _withSession { session, team in
			let portalCertificates = try await _portal.fetchCertificates(for: team, session: session)

			if let current = certificate,
			   ODKeychain.data(for: Key.p12) != nil,
			   portalCertificates.contains(where: { $0.serialNumberHex.caseInsensitiveCompare(current.serial) == .orderedSame }) {
				return
			}

			let deviceName = UIDevice.current.name
			let machineName = "Odysseus - \(deviceName)"

			let keyStore: KeyStore
			do {
				keyStore = try await _portal.addCertificate(machineName: machineName, type: .development, to: team, session: session)
			} catch DeveloperPortalError.tooManyCertificates {
				throw ODAppleIDError.tooManyCertificates(portalCertificates)
			}

			try _store(keyStore: keyStore, machineName: machineName)
		}

		if let certificate {
			await ODCertificateStatusStore.shared.check(der: certificate.der, key: ODCertificateStatusStore.appleIDKey, name: certificate.name)
		}
	}

	private func _store(keyStore: KeyStore, machineName: String) throws {
		let password = UUID().uuidString
		let p12 = try keyStore.exportP12(password: password)
		guard let der = keyStore.certificate.data else { throw ODAppleIDError.noCertificate }

		let info = ODAppleIDCertificateInfo(
			serial: keyStore.certificate.serialNumberHex,
			name: keyStore.certificate.name,
			machineName: machineName,
			expiration: keyStore.certificate.notAfter,
			der: der
		)

		ODKeychain.set(p12, for: Key.p12)
		ODKeychain.setString(password, for: Key.p12Password)
		ODKeychain.setCodable(info, for: Key.certificate)
		certificate = info
	}

	func portalCertificates() async throws -> [X509Certificate] {
		try await _withSession { session, team in
			try await _portal.fetchCertificates(for: team, session: session)
		}
	}

	/// Revokes a certificate on the Apple ID's team. Apps signed with it
	/// (by any tool, including the copy of Odysseus you're running if it
	/// was signed with this Apple ID) stop opening.
	func revoke(_ cert: X509Certificate) async throws {
		try await _withSession { session, team in
			_ = try await _portal.revokeCertificate(cert, for: team, session: session)
		}
		if let current = certificate, current.serial.caseInsensitiveCompare(cert.serialNumberHex) == .orderedSame {
			_clearCertificate()
		}
	}

	func checkCertificateStatus(force: Bool = false) async {
		guard let certificate else { return }
		let hours = UserDefaults.standard.integer(forKey: ODPrefs.ocspFrequencyHours)
		if !force,
		   let last = ODCertificateStatusStore.shared.results[ODCertificateStatusStore.appleIDKey]?.checkedAt,
		   Date().timeIntervalSince(last) < Double(max(hours, 1)) * 3600 {
			return
		}
		await ODCertificateStatusStore.shared.check(der: certificate.der, key: ODCertificateStatusStore.appleIDKey, name: certificate.name)
	}

	// MARK: Export
	/// Writes the certificate + private key as a password protected .p12.
	func exportP12(password: String) throws -> URL {
		guard
			let p12 = ODKeychain.data(for: Key.p12),
			let storedPassword = ODKeychain.string(for: Key.p12Password)
		else {
			throw ODAppleIDError.noCertificate
		}
		let keyStore = try KeyStore(p12Data: p12, password: storedPassword)
		let exported = try keyStore.exportP12(password: password)

		let name = "Odysseus-AppleID-\(account?.teamID ?? "certificate").p12"
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
		try? FileManager.default.removeItem(at: url)
		try exported.write(to: url, options: .completeFileProtection)
		return url
	}

	// MARK: Signing material
	/// Registers the device and App ID, downloads a profile and returns
	/// everything zsign needs to sign `bundleIdentifier`.
	func prepareSigning(bundleIdentifier original: String, appName: String) async throws -> ODAppleIDSigningMaterial {
		guard isSignedIn else { throw ODAppleIDError.notSignedIn }
		guard let udid = deviceUDID else { throw ODAppleIDError.missingUDID }

		isWorking = true
		defer { isWorking = false }

		try await ensureCertificate()

		guard
			let p12 = ODKeychain.data(for: Key.p12),
			let p12Password = ODKeychain.string(for: Key.p12Password)
		else {
			throw ODAppleIDError.noCertificate
		}

		let deviceType = _deviceType

		return try await _withSession { session, team in
			// 1. This device
			let devices = try await _portal.fetchDevices(for: team, types: .all, session: session)
			if !devices.contains(where: { $0.identifier.caseInsensitiveCompare(udid) == .orderedSame }) {
				_ = try await _portal.registerDevice(
					name: UIDevice.current.name,
					identifier: udid,
					type: deviceType,
					team: team,
					session: session
				)
			}

			// 2. App ID
			var bundleID = original
			if UserDefaults.standard.bool(forKey: ODPrefs.appleIDAppendTeamID), !bundleID.hasSuffix(".\(team.identifier)") {
				bundleID = "\(bundleID).\(team.identifier)"
			}

			let appIDs = try await _portal.fetchAppIDs(for: team, session: session)
			let appID: AppID
			if let existing = appIDs.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame }) {
				appID = existing
			} else {
				do {
					appID = try await _portal.addAppID(withName: Self._appIDName(appName), bundleIdentifier: bundleID, team: team, session: session)
				} catch DeveloperPortalError.maximumAppIDLimitReached(let cause) {
					throw ODAppleIDError.appIDLimit(cause)
				}
			}

			// 3. Profile
			let profile = try await _portal.downloadProvisioningProfile(for: appID, deviceType: deviceType, team: team, session: session)

			// 4. Files for zsign
			let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OdysseusAppleID_\(UUID().uuidString)", isDirectory: true)
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			let p12URL = dir.appendingPathComponent("appleid.p12")
			let provisionURL = dir.appendingPathComponent("appleid.mobileprovision")
			try p12.write(to: p12URL, options: .completeFileProtection)
			try profile.data.write(to: provisionURL)

			return ODAppleIDSigningMaterial(
				p12URL: p12URL,
				p12Password: p12Password,
				provisionURL: provisionURL,
				bundleIdentifier: bundleID,
				expiration: profile.expirationDate,
				teamID: team.identifier
			)
		}
	}

	private static func _appIDName(_ name: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(.whitespaces)
		let cleaned = String(name.unicodeScalars.filter { allowed.contains($0) })
			.trimmingCharacters(in: .whitespaces)
		return cleaned.isEmpty ? "Odysseus App" : String(cleaned.prefix(50))
	}
}

// MARK: - Apps signed with the Apple ID
/// Remembers which signed apps used the Apple ID and when their
/// 7-day profile runs out.
final class ODAppleIDSignedApps {
	static let shared = ODAppleIDSignedApps()

	struct Info: Codable {
		var name: String
		var bundleIdentifier: String
		var expiration: Date
		var teamID: String
	}

	private let _key = "Odysseus.appleIDSignedApps"

	func all() -> [String: Info] {
		guard let data = UserDefaults.standard.data(forKey: _key) else { return [:] }
		return (try? JSONDecoder().decode([String: Info].self, from: data)) ?? [:]
	}

	func info(for uuid: String?) -> Info? {
		guard let uuid else { return nil }
		return all()[uuid]
	}

	func set(_ info: Info?, for uuid: String) {
		var current = all()
		current[uuid] = info
		if let data = try? JSONEncoder().encode(current) {
			UserDefaults.standard.set(data, forKey: _key)
		}
	}
}
