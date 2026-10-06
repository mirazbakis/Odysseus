//
//  ODCertificateStatusStore.swift
//  Odysseus
//
//  Keeps the latest OCSP result per certificate, re-checks on a
//  schedule, and tells the user when a status changes.
//
//  Stored as JSON next to the Core Data store so the data model
//  doesn't need a migration.
//

import Foundation
import SwiftUI
import UserNotifications
import OSLog

@MainActor
final class ODCertificateStatusStore: ObservableObject {
	static let shared = ODCertificateStatusStore()

	@Published private(set) var results: [String: ODOCSPResult] = [:]
	@Published private(set) var checking: Set<String> = []

	private let _fileURL: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent("Odysseus", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("certificate-status.json")
	}()

	private init() {
		if let data = try? Data(contentsOf: _fileURL) {
			let decoder = JSONDecoder()
			decoder.dateDecodingStrategy = .iso8601
			results = (try? decoder.decode([String: ODOCSPResult].self, from: data)) ?? [:]
		}
	}

	// MARK: Keys
	static func key(for cert: CertificatePair) -> String {
		"cert:\(cert.uuid ?? "?")"
	}

	static let appleIDKey = "appleid"

	func result(for cert: CertificatePair) -> ODOCSPResult? {
		results[Self.key(for: cert)]
	}

	func isChecking(_ cert: CertificatePair) -> Bool {
		checking.contains(Self.key(for: cert))
	}

	func isRevoked(_ cert: CertificatePair) -> Bool {
		result(for: cert)?.status == .revoked
	}

	// MARK: Checking
	@discardableResult
	func check(_ cert: CertificatePair) async -> ODOCSPResult {
		let key = Self.key(for: cert)
		let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("Certificate")

		guard let der = ODCertificateLoader.certificateDER(for: cert) else {
			let result = ODOCSPResult.couldntCheck(.localized("The certificate file couldn't be opened. Check the password."))
			_store(result, for: key, name: name)
			return result
		}

		let result = await check(der: der, key: key, name: name)

		// Keep Feather's flag in sync, in both directions.
		switch result.status {
		case .revoked:
			if !cert.revoked { cert.revoked = true; Storage.shared.saveContext() }
		case .valid:
			if cert.revoked { cert.revoked = false; Storage.shared.saveContext() }
		default:
			break
		}
		return result
	}

	@discardableResult
	func check(der: Data, key: String, name: String) async -> ODOCSPResult {
		checking.insert(key)
		defer { checking.remove(key) }
		let result = await ODOCSPChecker.check(certificateDER: der)
		_store(result, for: key, name: name)
		return result
	}

	/// Checks every certificate whose last check is older than the
	/// configured frequency (or all of them with `force`).
	func checkAllIfNeeded(force: Bool = false) async {
		let hours = UserDefaults.standard.integer(forKey: ODPrefs.ocspFrequencyHours)
		guard force || hours > 0 else { return }

		for cert in Storage.shared.getAllCertificates() {
			if !force, let last = result(for: cert)?.checkedAt, Date().timeIntervalSince(last) < Double(hours) * 3600 {
				continue
			}
			await check(cert)
		}

		if ODAppleIDManager.shared.isSignedIn {
			await ODAppleIDManager.shared.checkCertificateStatus(force: force)
		}

		ODExpiryReminderScheduler.reschedule()
	}

	func remove(_ cert: CertificatePair) {
		results.removeValue(forKey: Self.key(for: cert))
		_save()
	}

	func removeValue(forKey key: String) {
		results.removeValue(forKey: key)
		_save()
	}

	// MARK: Store
	private func _store(_ result: ODOCSPResult, for key: String, name: String) {
		let previous = results[key]
		results[key] = result
		_save()

		// Only real status changes are worth a notification, not a
		// flaky network ("couldn't check").
		guard
			let previous,
			previous.status != result.status,
			result.status != .couldntCheck,
			UserDefaults.standard.bool(forKey: ODPrefs.ocspNotifyOnChange)
		else {
			return
		}

		ODNotifications.post(
			title: result.status == .revoked
				? .localized("Certificate revoked")
				: .localized("Certificate status changed"),
			body: .localized("%@ is now %@.", arguments: name, result.title),
			id: "ocsp.\(key)"
		)
	}

	private func _save() {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(results) {
			try? data.write(to: _fileURL, options: .atomic)
		}
	}
}

// MARK: - Notifications
enum ODNotifications {
	static func requestAuthorization() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
	}

	static func post(title: String, body: String, id: String, at date: Date? = nil) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default

		var trigger: UNNotificationTrigger?
		if let date {
			let interval = date.timeIntervalSinceNow
			guard interval > 1 else { return }
			trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
		}

		let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
		UNUserNotificationCenter.current().add(request)
	}

	static func cancel(prefix: String) {
		let center = UNUserNotificationCenter.current()
		center.getPendingNotificationRequests { requests in
			let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
			center.removePendingNotificationRequests(withIdentifiers: ids)
		}
	}
}

// MARK: - Expiry reminders
enum ODExpiryReminderScheduler {
	/// Schedules a reminder `expiryWarningDays` before each certificate
	/// (and each Apple ID signed app) expires.
	@MainActor
	static func reschedule() {
		ODNotifications.cancel(prefix: "expiry.")
		guard UserDefaults.standard.bool(forKey: ODPrefs.expiryReminders) else { return }

		let days = max(1, UserDefaults.standard.integer(forKey: ODPrefs.expiryWarningDays))

		for cert in Storage.shared.getAllCertificates() {
			guard let expiration = cert.expiration else { continue }
			let name = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("A certificate")
			ODNotifications.post(
				title: .localized("Certificate expiring soon"),
				body: .localized("%@ expires in %lld days.", arguments: name, days),
				id: "expiry.cert.\(cert.uuid ?? UUID().uuidString)",
				at: expiration.addingTimeInterval(-Double(days) * 86_400)
			)
		}

		for (uuid, info) in ODAppleIDSignedApps.shared.all() {
			ODNotifications.post(
				title: .localized("App expiring soon"),
				body: .localized("%@ (signed with your Apple ID) expires in %lld days. Sign it again to keep using it.", arguments: info.name, days),
				id: "expiry.app.\(uuid)",
				at: info.expiration.addingTimeInterval(-Double(days) * 86_400)
			)
		}
	}
}
