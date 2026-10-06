//
//  ODSignPipeline.swift
//  Odysseus
//
//  One place for "sign this app" and "get this app":
//    - picks the signing identity (imported certificate or Apple ID),
//    - checks revocation first (warn / block / allow, from Settings),
//    - applies the bundle ID prefix/suffix,
//    - signs with zsign through the usual SigningHandler,
//    - then asks the root view to show the install sheet.
//
//  Get on Discover = download → import → sign → install, in one tap.
//

import Foundation
import SwiftUI
import CoreData
import AltSourceKit
import OSLog

extension Notification.Name {
	/// object: Signed app UUID (String). Shows the install sheet.
	static let odysseusPresentInstall = Notification.Name("Odysseus.presentInstall")
}

enum ODSigningIdentity {
	case certificate(CertificatePair?)
	case appleID
}

enum ODSignError: LocalizedError {
	case noCertificate
	case revokedBlocked(String)
	case cancelled
	case importFailed

	var errorDescription: String? {
		switch self {
		case .noCertificate:
			return .localized("Add a certificate in Library or sign in with your Apple ID in Settings first.")
		case .revokedBlocked(let name):
			return .localized("%@ is revoked, so signing is blocked. You can change this in Settings → Certificates.", arguments: name)
		case .cancelled:
			return .localized("Cancelled.")
		case .importFailed:
			return .localized("The app couldn't be opened after downloading.")
		}
	}
}

@MainActor
final class ODSignPipeline: ObservableObject {
	static let shared = ODSignPipeline()

	enum GetPhase: Equatable {
		case downloading
		case signing
		case failed(String)
	}

	/// Download id (app unique id) → what the Get button should show.
	@Published private(set) var phases: [String: GetPhase] = [:]

	private var _pendingGets: Set<String> = []
	private var _observer: NSObjectProtocol?

	private init() {
		_observer = NotificationCenter.default.addObserver(
			forName: .odysseusDidImportApp,
			object: nil,
			queue: .main
		) { notification in
			guard let uuid = notification.object as? String else { return }
			if notification.userInfo?["remote"] as? Bool == true {
				ODDownloadOrigin.markDownloaded(uuid)
			}
			guard let downloadID = notification.userInfo?["downloadID"] as? String else { return }
			Task { @MainActor in
				ODSignPipeline.shared._didImport(uuid: uuid, downloadID: downloadID)
			}
		}
	}

	// MARK: Identity
	var defaultCertificate: CertificatePair? {
		let certificates = Storage.shared.getAllCertificates()
		let index = UserDefaults.standard.integer(forKey: ODPrefs.defaultCertificate)
		return certificates.indices.contains(index) ? certificates[index] : certificates.first
	}

	var defaultIdentity: ODSigningIdentity {
		if ODPrefs.signingIdentityKind == .appleID, ODAppleIDManager.shared.isSignedIn {
			return .appleID
		}
		if defaultCertificate == nil, ODAppleIDManager.shared.isSignedIn {
			return .appleID
		}
		return .certificate(defaultCertificate)
	}

	/// The usual tweaks SigningView applies when it opens.
	func defaultOptions(for app: AppInfoPresentable, certificate: CertificatePair?) -> Options {
		var options = OptionsManager.shared.options

		if options.ppqProtection, certificate?.ppQCheck == true, let identifier = app.identifier {
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}
		if let current = app.identifier, let replacement = options.identifiers[current] {
			options.appIdentifier = replacement
		}
		if let name = app.name, let replacement = options.displayNames[name] {
			options.appName = replacement
		}
		return options
	}

	// MARK: Sign
	/// Signs `app` and returns the new Signed app's UUID.
	@discardableResult
	func sign(
		_ app: AppInfoPresentable,
		options inputOptions: Options,
		icon: UIImage? = nil,
		identity: ODSigningIdentity
	) async throws -> String {
		var options = inputOptions
		var certificate: CertificatePair?
		var identityOverride: ODSigningOverride?
		var appleIDMaterial: ODAppleIDSigningMaterial?

		if UserDefaults.standard.bool(forKey: ODPrefs.autoDeleteIPAs) {
			options.post_deleteAppAfterSigned = true
		}

		// Bundle ID prefix / suffix from Settings.
		if let base = options.appIdentifier ?? app.identifier {
			let adjusted = ODPrefs.adjustedBundleID(base)
			if adjusted != base || options.appIdentifier != nil {
				options.appIdentifier = adjusted
			}
		}

		switch identity {
		case .certificate(let cert):
			guard options.signingOption != .default || cert != nil else {
				throw ODSignError.noCertificate
			}
			if let cert {
				try await _revocationGate(
					result: await _freshResult(for: cert),
					name: cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? .localized("This certificate")
				)
			}
			certificate = cert

		case .appleID:
			let manager = ODAppleIDManager.shared
			let base = options.appIdentifier ?? app.identifier ?? "com.odysseus.app"
			let material = try await manager.prepareSigning(
				bundleIdentifier: base,
				appName: options.appName ?? app.name ?? "App"
			)
			if let status = ODCertificateStatusStore.shared.results[ODCertificateStatusStore.appleIDKey] {
				try await _revocationGate(result: status, name: .localized("Your Apple ID certificate"))
			}
			options.appIdentifier = material.bundleIdentifier
			if UserDefaults.standard.bool(forKey: ODPrefs.appleIDRemoveExtensions) {
				// Each extension would need its own App ID and profile.
				for folder in ["PlugIns", "Extensions"] where !options.removeFiles.contains(folder) {
					options.removeFiles.append(folder)
				}
			}
			identityOverride = ODSigningOverride(
				p12Path: material.p12URL.path,
				p12Password: material.p12Password,
				provisionPath: material.provisionURL.path
			)
			appleIDMaterial = material
		}

		let signedUUID: String = try await withCheckedThrowingContinuation { continuation in
			FR.signPackageFile(
				app,
				using: options,
				icon: icon,
				certificate: certificate,
				identityOverride: identityOverride
			) { error, uuid in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: uuid ?? "")
				}
			}
		}

		if let material = appleIDMaterial {
			try? FileManager.default.removeItem(at: material.p12URL.deletingLastPathComponent())
			ODAppleIDSignedApps.shared.set(
				ODAppleIDSignedApps.Info(
					name: options.appName ?? app.name ?? "App",
					bundleIdentifier: material.bundleIdentifier,
					expiration: material.expiration,
					teamID: material.teamID
				),
				for: signedUUID
			)
			ODExpiryReminderScheduler.reschedule()
		}

		if options.post_deleteAppAfterSigned, !app.isSigned {
			Storage.shared.deleteApp(for: app)
		}

		return signedUUID
	}

	/// Shows the install sheet for a signed app.
	func install(signedUUID: String?) {
		NotificationCenter.default.post(name: .odysseusPresentInstall, object: signedUUID)
	}

	/// Sign with the defaults and install. Shows errors as alerts.
	func signAndInstall(_ app: AppInfoPresentable, identity: ODSigningIdentity? = nil) async -> Bool {
		let identity = identity ?? defaultIdentity
		var certificate: CertificatePair?
		if case .certificate(let cert) = identity { certificate = cert }

		var options = defaultOptions(for: app, certificate: certificate)
		options.post_installAppAfterSigned = true

		do {
			let uuid = try await sign(app, options: options, identity: identity)
			ODTheme.success()
			install(signedUUID: uuid)
			return true
		} catch ODSignError.cancelled {
			return false
		} catch {
			ODTheme.failure()
			UIAlertController.showAlertWithOk(
				title: .localized("Couldn't sign app"),
				message: error.localizedDescription
			)
			return false
		}
	}

	// MARK: Get (download → sign → install)
	func get(_ app: ASRepository.App) {
		guard let url = app.currentDownloadUrl else { return }
		let id = app.currentUniqueId

		if case .certificate(.none) = defaultIdentity {
			// Nothing to sign with: just download, like before.
			_ = DownloadManager.shared.startDownload(from: url, id: id)
			UIAlertController.showAlertWithOk(
				title: .localized("Downloading only"),
				message: .localized("There's no certificate or Apple ID to sign with yet, so the app will be saved to your Library. Add a certificate in Library or sign in with your Apple ID in Settings to install apps in one tap.")
			)
			return
		}

		_pendingGets.insert(id)
		phases[id] = .downloading
		_ = DownloadManager.shared.startDownload(from: url, id: id)
	}

	func cancelGet(_ id: String) {
		_pendingGets.remove(id)
		phases[id] = nil
		if let download = DownloadManager.shared.getDownload(by: id) {
			DownloadManager.shared.cancelDownload(download)
		}
	}

	func clearFailure(_ id: String) {
		if case .failed = phases[id] { phases[id] = nil }
	}

	/// The download finished; sees whether nothing else is running for it
	/// (a failed download never imports) and cleans up.
	func downloadEnded(_ id: String) {
		guard _pendingGets.contains(id) else { return }
		if DownloadManager.shared.getDownload(by: id) == nil, phases[id] == .downloading {
			// Give the import notification a moment to arrive.
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 3_000_000_000)
				if self.phases[id] == .downloading, DownloadManager.shared.getDownload(by: id) == nil {
					self._pendingGets.remove(id)
					self.phases[id] = .failed(.localized("Download failed"))
				}
			}
		}
	}

	private func _didImport(uuid: String, downloadID: String) {
		guard _pendingGets.remove(downloadID) != nil else { return }

		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		request.fetchLimit = 1

		guard let imported = try? Storage.shared.context.fetch(request).first else {
			phases[downloadID] = .failed(ODSignError.importFailed.localizedDescription)
			return
		}

		phases[downloadID] = .signing
		Task { @MainActor in
			let ok = await signAndInstall(imported)
			phases[downloadID] = ok ? nil : .failed(.localized("Signing failed"))
		}
	}

	// MARK: Revocation
	private func _freshResult(for cert: CertificatePair) async -> ODOCSPResult? {
		let store = ODCertificateStatusStore.shared
		if let result = store.result(for: cert), Date().timeIntervalSince(result.checkedAt) < 3600 {
			return result
		}
		let action = ODPrefs.revokedAction
		guard action != .allow else { return store.result(for: cert) }
		return await store.check(cert)
	}

	private func _revocationGate(result: ODOCSPResult?, name: String) async throws {
		guard let result, result.status == .revoked else { return }

		switch ODPrefs.revokedAction {
		case .allow:
			return
		case .block:
			ODTheme.failure()
			throw ODSignError.revokedBlocked(name)
		case .warn:
			ODTheme.warning()
			let proceed = await _confirm(
				title: .localized("Certificate revoked"),
				message: .localized("%@ was revoked by Apple%@. Apps signed with it won't open. Sign anyway?",
					arguments: name,
					result.revokedAt.map { " " + String.localized("on %@", arguments: DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)) } ?? ""
				)
			)
			if !proceed { throw ODSignError.cancelled }
		}
	}

	private func _confirm(title: String, message: String) async -> Bool {
		await withCheckedContinuation { continuation in
			let cancel = UIAlertAction(title: .localized("Cancel"), style: .cancel) { _ in
				continuation.resume(returning: false)
			}
			let proceed = UIAlertAction(title: .localized("Sign Anyway"), style: .destructive) { _ in
				continuation.resume(returning: true)
			}
			UIAlertController.showAlert(title: title, message: message, actions: [cancel, proceed])
		}
	}
}

// MARK: - Download origin
/// Remembers which library apps came from Discover / a link, so the
/// Library can show "Downloaded" separately from "Imported" files.
enum ODDownloadOrigin {
	private static let _key = "Odysseus.downloadedAppUUIDs"

	static func markDownloaded(_ uuid: String) {
		var set = Set(UserDefaults.standard.stringArray(forKey: _key) ?? [])
		set.insert(uuid)
		UserDefaults.standard.set(Array(set), forKey: _key)
	}

	static func isDownloaded(_ uuid: String?) -> Bool {
		guard let uuid else { return false }
		return (UserDefaults.standard.stringArray(forKey: _key) ?? []).contains(uuid)
	}
}
