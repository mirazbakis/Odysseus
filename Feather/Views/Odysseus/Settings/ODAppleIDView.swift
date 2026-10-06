//
//  ODAppleIDView.swift
//  Odysseus
//
//  Sign in with your own Apple ID, see the Odysseus certificate,
//  export it as a .p12 (with a warning), manage the team's
//  certificates and set the device UDID / anisette server.
//

import SwiftUI
import SideSign
import LocalAuthentication

struct ODAppleIDView: View {
	@ObservedObject private var _manager = ODAppleIDManager.shared
	@ObservedObject private var _store = ODCertificateStatusStore.shared

	@AppStorage(ODPrefs.appleIDAppendTeamID) private var _appendTeamID = true
	@AppStorage(ODPrefs.appleIDRemoveExtensions) private var _removeExtensions = true
	@AppStorage(ODAppleIDManager.manualUDIDKey) private var _manualUDID = ""
	@AppStorage(ODAppleIDManager.anisetteServersKey) private var _anisetteServers = ODAppleIDManager.defaultAnisetteServer

	@State private var _isSigningIn = false
	@State private var _isExportWarningPresented = false
	@State private var _isExportPasswordPresented = false
	@State private var _exportPassword = ""
	@State private var _portalCertificates: [X509Certificate] = []
	@State private var _isLoadingPortal = false
	@State private var _certificateToRevoke: X509Certificate?
	@State private var _isSignOutPresented = false

	var body: some View {
		List {
			if _manager.isSignedIn {
				_accountSection
				_certificateSection
				_signingSection
				_portalSection
			} else {
				_signedOutSection
			}
			_deviceSection
			_anisetteSection
			if _manager.isSignedIn {
				Section {
					Button(.localized("Sign Out"), role: .destructive) {
						_isSignOutPresented = true
					}
					.listRowBackground(ODTheme.navy)
				}
			}
		}
		.odPageBackground()
		.navigationTitle(.localized("Apple ID"))
		.sheet(isPresented: $_isSigningIn) {
			ODAppleIDSignInView()
		}
		.alert(.localized("Export your private key?"), isPresented: $_isExportWarningPresented) {
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("I Understand"), role: .destructive) {
				_authenticateThenAskPassword()
			}
		} message: {
			Text(.localized("A .p12 holds your certificate AND its private key. Anyone who has it can sign apps as you, and Apple may revoke the certificate if it gets shared. Free accounts can only have a couple of certificates, and a revoked one stops every app signed with it. Only keep it somewhere private."))
		}
		.alert(.localized("Choose a password"), isPresented: $_isExportPasswordPresented) {
			SecureField(.localized("Password"), text: $_exportPassword)
			Button(.localized("Cancel"), role: .cancel) { _exportPassword = "" }
			Button(.localized("Export")) { _export() }
		} message: {
			Text(.localized("The .p12 is encrypted with this password. You'll need it to import the file anywhere else."))
		}
		.alert(.localized("Revoke certificate?"), isPresented: Binding(get: { _certificateToRevoke != nil }, set: { if !$0 { _certificateToRevoke = nil } }), presenting: _certificateToRevoke) { cert in
			Button(.localized("Cancel"), role: .cancel) {}
			Button(.localized("Revoke"), role: .destructive) { _revoke(cert) }
		} message: { cert in
			Text(verbatim: .localized("%@ will stop working, along with every app signed with it, including apps from SideStore, AltStore or Sideloadly, and this copy of Odysseus if it was signed with the same Apple ID.", arguments: cert.machineName ?? cert.name))
		}
		.confirmationDialog(.localized("Sign out?"), isPresented: $_isSignOutPresented, titleVisibility: .visible) {
			Button(.localized("Sign Out, Keep Certificate")) { _manager.signOut(keepCertificate: true) }
			Button(.localized("Sign Out and Forget Certificate"), role: .destructive) { _manager.signOut() }
		} message: {
			Text(.localized("Apps you already signed keep working until they expire."))
		}
		.task {
			if _manager.isSignedIn, _portalCertificates.isEmpty {
				await _loadPortal()
			}
		}
	}

	// MARK: Signed out
	private var _signedOutSection: some View {
		Section {
			VStack(alignment: .leading, spacing: 12) {
				Image(systemName: "person.crop.circle.badge.plus")
					.font(.system(size: 40))
					.foregroundStyle(Color.accentColor)
				Text(.localized("Use your own Apple ID"))
					.font(.system(.title3, design: .rounded).weight(.bold))
					.foregroundStyle(.white)
				Text(.localized("Odysseus makes a development certificate on your Apple ID and signs apps for this device with it. Free Apple IDs: apps last 7 days, up to 3 at a time, 10 new App IDs a week."))
					.font(.subheadline)
					.foregroundStyle(.secondary)
				Button(.localized("Sign In")) { _isSigningIn = true }
					.buttonStyle(ODProminentButtonStyle())
					.padding(.top, 4)
			}
			.padding(.vertical, 8)
			.listRowBackground(ODTheme.navy)
		} footer: {
			Text(.localized("Your password goes to Apple only. Anisette data (needed by Apple's login) comes from the anisette server below, like SideStore."))
		}
	}

	// MARK: Account
	private var _accountSection: some View {
		Section {
			LabeledContent(.localized("Apple ID"), value: _manager.account?.appleID ?? "")
			LabeledContent(.localized("Name"), value: _manager.account?.displayName ?? "")
			if _manager.availableTeams.count > 1 {
				Picker(.localized("Team"), selection: Binding(
					get: { _manager.account?.teamID ?? "" },
					set: { id in
						if let team = _manager.availableTeams.first(where: { $0.identifier == id }) {
							_manager.select(team: team)
						}
					}
				)) {
					ForEach(_manager.availableTeams, id: \.identifier) { team in
						Text(verbatim: "\(team.name) (\(team.type.displayName))").tag(team.identifier)
					}
				}
			} else {
				LabeledContent(.localized("Team"), value: "\(_manager.account?.teamName ?? "") · \(_manager.account?.teamID ?? "")")
			}
		} header: {
			Text(.localized("Account"))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Certificate
	private var _certificateSection: some View {
		Section {
			if let certificate = _manager.certificate {
				LabeledContent(.localized("Name"), value: certificate.machineName ?? certificate.name)
				LabeledContent(.localized("Serial"), value: certificate.serial)
				if let expiration = certificate.expiration {
					HStack {
						Text(.localized("Expires"))
						Spacer()
						ODExpiryPill(expiration: expiration)
					}
				}
				HStack {
					Text(.localized("Revocation"))
					Spacer()
					if _store.checking.contains(ODCertificateStatusStore.appleIDKey) {
						ProgressView()
					} else {
						ODOCSPPill(result: _store.results[ODCertificateStatusStore.appleIDKey])
					}
				}
				Button(.localized("Check Now"), systemImage: "arrow.clockwise") {
					Task { await _manager.checkCertificateStatus(force: true) }
				}
				Button(.localized("Export .p12…"), systemImage: "square.and.arrow.up") {
					_isExportWarningPresented = true
				}
			} else {
				Text(.localized("No certificate yet. One is made the first time you sign an app."))
					.foregroundStyle(.secondary)
				Button(.localized("Make Certificate Now"), systemImage: "plus.circle") {
					Task { await _run { try await _manager.ensureCertificate() } }
				}
				.disabled(_manager.isWorking)
			}
		} header: {
			Text(.localized("Odysseus Certificate"))
		} footer: {
			if let error = _manager.lastError {
				Text(error).foregroundStyle(ODTheme.revoked)
			}
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Signing
	private var _signingSection: some View {
		Section {
			Toggle(.localized("Add Team ID to Bundle IDs"), isOn: $_appendTeamID)
			Toggle(.localized("Remove App Extensions"), isOn: $_removeExtensions)
		} header: {
			Text(.localized("Signing"))
		} footer: {
			Text(.localized("Bundle IDs are unique across all Apple IDs, so adding your Team ID avoids \"not available\" errors. Each app extension would need its own App ID, which eats into the 10-per-week limit."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Portal certificates
	private var _portalSection: some View {
		Section {
			if _isLoadingPortal {
				ProgressView()
			} else if _portalCertificates.isEmpty {
				Text(.localized("No certificates on this team."))
					.foregroundStyle(.secondary)
			} else {
				ForEach(_portalCertificates, id: \.serialNumberHex) { cert in
					let isOurs = cert.serialNumberHex.caseInsensitiveCompare(_manager.certificate?.serial ?? "") == .orderedSame
					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text(cert.machineName ?? cert.name)
								.lineLimit(1)
							Text(verbatim: "\(cert.serialNumberHex.prefix(12))… · \(cert.expiryDate.formatted(date: .abbreviated, time: .omitted))")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						if isOurs {
							ODPill(text: .localized("Odysseus"), color: Color.accentColor)
						}
					}
					.swipeActions {
						Button(.localized("Revoke"), role: .destructive) {
							_certificateToRevoke = cert
						}
					}
					.contextMenu {
						Button(.localized("Revoke…"), systemImage: "xmark.octagon", role: .destructive) {
							_certificateToRevoke = cert
						}
					}
				}
			}
			Button(.localized("Refresh"), systemImage: "arrow.clockwise") {
				Task { await _loadPortal() }
			}
		} header: {
			Text(.localized("Certificates on This Apple ID"))
		} footer: {
			Text(.localized("If Odysseus can't make a certificate because the limit is reached, revoke one here. Swipe to revoke."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Device
	private var _deviceSection: some View {
		Section {
			LabeledContent(.localized("UDID"), value: _manager.deviceUDID ?? String.localized("Not found"))
			TextField(.localized("Enter UDID manually"), text: $_manualUDID)
				.textInputAutocapitalization(.characters)
				.autocorrectionDisabled()
				.font(.system(.body, design: .monospaced))
		} header: {
			Text(.localized("This Device"))
		} footer: {
			Text(.localized("Profiles only work on registered devices. Odysseus reads the UDID from your pairing file (Settings → Installation). Leave the field empty to use it."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Anisette
	private var _anisetteSection: some View {
		Section {
			TextField(ODAppleIDManager.defaultAnisetteServer, text: $_anisetteServers, axis: .vertical)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.keyboardType(.URL)
			Button(.localized("Reset to Default")) {
				_anisetteServers = ODAppleIDManager.defaultAnisetteServer
			}
		} header: {
			Text(.localized("Anisette Servers"))
		} footer: {
			Text(.localized("One URL per line. Odysseus tries them in order."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Actions
	private func _run(_ work: @escaping () async throws -> Void) async {
		do {
			try await work()
		} catch {
			UIAlertController.showAlertWithOk(title: .localized("Apple ID"), message: error.localizedDescription)
		}
	}

	private func _loadPortal() async {
		_isLoadingPortal = true
		defer { _isLoadingPortal = false }
		do {
			_portalCertificates = try await _manager.portalCertificates()
		} catch {
			_manager.lastError = error.localizedDescription
		}
	}

	private func _revoke(_ cert: X509Certificate) {
		Task {
			await _run { try await _manager.revoke(cert) }
			await _loadPortal()
		}
	}

	private func _authenticateThenAskPassword() {
		let context = LAContext()
		var error: NSError?
		guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
			_isExportPasswordPresented = true
			return
		}
		context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: .localized("Export your Apple ID certificate")) { success, _ in
			Task { @MainActor in
				if success { _isExportPasswordPresented = true }
			}
		}
	}

	private func _export() {
		let password = _exportPassword
		_exportPassword = ""
		guard !password.isEmpty else {
			UIAlertController.showAlertWithOk(title: .localized("Password needed"), message: .localized("Choose a password to protect the .p12."))
			return
		}
		do {
			let url = try _manager.exportP12(password: password)
			UIActivityViewController.show(activityItems: [url])
		} catch {
			UIAlertController.showAlertWithOk(title: .localized("Couldn't export"), message: error.localizedDescription)
		}
	}
}

// MARK: - Sign in
struct ODAppleIDSignInView: View {
	@Environment(\.dismiss) private var _dismiss
	@ObservedObject private var _manager = ODAppleIDManager.shared

	@State private var _appleID = ""
	@State private var _password = ""
	@State private var _rememberPassword = true
	@State private var _error: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField(.localized("Apple ID"), text: $_appleID)
						.textContentType(.username)
						.keyboardType(.emailAddress)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					SecureField(.localized("Password"), text: $_password)
						.textContentType(.password)
				} footer: {
					Text(.localized("Use a secondary Apple ID if you can. Apple may lock accounts that sign apps from many places."))
				}
				.listRowBackground(ODTheme.navy)

				Section {
					Toggle(.localized("Remember Password"), isOn: $_rememberPassword)
				} footer: {
					Text(.localized("Kept in this device's Keychain so Odysseus can sign in again by itself when Apple's session runs out."))
				}
				.listRowBackground(ODTheme.navy)

				if let _error {
					Section {
						Text(_error).foregroundStyle(ODTheme.revoked)
					}
					.listRowBackground(ODTheme.navy)
				}
			}
			.odPageBackground()
			.navigationTitle(.localized("Sign In"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(.localized("Cancel")) { _dismiss() }
						.disabled(_manager.isWorking)
				}
				ToolbarItem(placement: .confirmationAction) {
					if _manager.isWorking {
						ProgressView()
					} else {
						Button(.localized("Sign In")) { _signIn() }
							.disabled(_appleID.isEmpty || _password.isEmpty)
					}
				}
			}
		}
		.interactiveDismissDisabled(_manager.isWorking)
	}

	private func _signIn() {
		_error = nil
		Task {
			do {
				try await _manager.signIn(
					appleID: _appleID.trimmingCharacters(in: .whitespaces),
					password: _password,
					rememberPassword: _rememberPassword
				)
				ODTheme.success()
				_dismiss()
			} catch ODAppleIDError.cancelled {
				_error = nil
			} catch {
				ODTheme.failure()
				_error = error.localizedDescription
			}
		}
	}
}
