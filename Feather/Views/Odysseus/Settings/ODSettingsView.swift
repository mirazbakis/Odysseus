//
//  ODSettingsView.swift
//  Odysseus
//

import SwiftUI
import NimbleViews
import Nuke
import IDeviceSwift

struct ODSettingsView: View {
	@ObservedObject private var _appleID = ODAppleIDManager.shared
	@ObservedObject private var _statusStore = ODCertificateStatusStore.shared

	@AppStorage(ODPrefs.signingIdentity) private var _identity = ODPrefs.SigningIdentityKind.certificate.rawValue
	@AppStorage(ODPrefs.bundleIDPrefix) private var _prefix = ""
	@AppStorage(ODPrefs.bundleIDSuffix) private var _suffix = ""
	@AppStorage(ODPrefs.ocspFrequencyHours) private var _ocspHours = 24
	@AppStorage(ODPrefs.ocspActionOnRevoked) private var _revokedAction = ODPrefs.RevokedAction.warn.rawValue
	@AppStorage(ODPrefs.ocspNotifyOnChange) private var _notifyOnChange = true
	@AppStorage(ODPrefs.expiryReminders) private var _expiryReminders = true
	@AppStorage(ODPrefs.expiryWarningDays) private var _warningDays = 3
	@AppStorage(ODPrefs.installationMethod) private var _installMethod = 0
	@AppStorage(ODPrefs.customPlistServer) private var _plistServer = ""
	@AppStorage(ODPrefs.autoDeleteIPAs) private var _autoDelete = false
	@AppStorage(ODPrefs.sourceAutoRefreshHours) private var _sourceRefreshHours = 6
	@AppStorage(ODPrefs.combineDuplicates) private var _combineDuplicates = true
	@AppStorage(ODPrefs.defaultCertificate) private var _selectedCert = 0

	@State private var _isCheckingAll = false
	@State private var _cacheCleared = false

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>

	var body: some View {
		NavigationStack {
			List {
				_header
				_signing
				_revocation
				_installing
				_sources
				_appearance
				_storage
				_about
			}
			.odPageBackground()
			.navigationTitle(.localized("Settings"))
		}
	}

	// MARK: Header
	private var _header: some View {
		Section {
			VStack(spacing: 10) {
				ODLogoView(size: 76)
				VStack(spacing: 2) {
					Text(verbatim: "Odysseus")
						.font(.system(.title2, design: .rounded).weight(.bold))
						.foregroundStyle(.white)
					Text(verbatim: "An app by mbakis · \(Bundle.main.version)")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 8)
			.listRowBackground(Color.clear)
		}
	}

	// MARK: Signing
	private var _signing: some View {
		Section {
			Picker(.localized("Sign With"), selection: $_identity) {
				ForEach(ODPrefs.SigningIdentityKind.allCases) { kind in
					Text(kind.title).tag(kind.rawValue)
				}
			}

			NavigationLink {
				CertificatesView()
					.odPageBackground()
			} label: {
				HStack {
					Label(.localized("Certificates"), systemImage: "person.text.rectangle")
					Spacer()
					if _certificates.indices.contains(_selectedCert) {
						let cert = _certificates[_selectedCert]
						Text(cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? "")
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}
			}

			NavigationLink {
				ODAppleIDView()
			} label: {
				HStack {
					Label(.localized("Apple ID"), systemImage: "person.crop.circle")
					Spacer()
					Text(_appleID.account?.appleID ?? String.localized("Not signed in"))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}

			NavigationLink {
				ConfigurationView()
					.odPageBackground()
			} label: {
				Label(.localized("Signing Options"), systemImage: "signature")
			}

			NavigationLink {
				ODBundleIDView(prefix: $_prefix, suffix: $_suffix)
			} label: {
				HStack {
					Label(.localized("Bundle ID Prefix & Suffix"), systemImage: "textformat")
					Spacer()
					if !_prefix.isEmpty || !_suffix.isEmpty {
						Text(.localized("On")).foregroundStyle(.secondary)
					}
				}
			}
		} header: {
			Text(.localized("Signing"))
		} footer: {
			Text(.localized("The default for Get and one-tap installs. Odysseus never comes with certificates: import your own .p12 and .mobileprovision, or use your Apple ID."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Revocation
	private var _revocation: some View {
		Section {
			Picker(.localized("Check Revocation"), selection: $_ocspHours) {
				Text(.localized("Manually")).tag(0)
				Text(.localized("Every Hour")).tag(1)
				Text(.localized("Every 6 Hours")).tag(6)
				Text(.localized("Daily")).tag(24)
				Text(.localized("Weekly")).tag(168)
			}
			Picker(.localized("When Revoked"), selection: $_revokedAction) {
				ForEach(ODPrefs.RevokedAction.allCases) { action in
					Text(action.title).tag(action.rawValue)
				}
			}
			Toggle(.localized("Notify When Status Changes"), isOn: $_notifyOnChange)
				.onChange(of: _notifyOnChange) { on in if on { ODNotifications.requestAuthorization() } }
			Toggle(.localized("Expiry Reminders"), isOn: $_expiryReminders)
				.onChange(of: _expiryReminders) { on in
					if on { ODNotifications.requestAuthorization() }
					ODExpiryReminderScheduler.reschedule()
				}
			Stepper(value: $_warningDays, in: 1...30) {
				HStack {
					Text(.localized("Warn Before Expiry"))
					Spacer()
					Text(verbatim: .localized("%lld days", arguments: _warningDays))
						.foregroundStyle(.secondary)
				}
			}
			.onChange(of: _warningDays) { _ in ODExpiryReminderScheduler.reschedule() }
			Button {
				_isCheckingAll = true
				Task {
					await _statusStore.checkAllIfNeeded(force: true)
					_isCheckingAll = false
				}
			} label: {
				HStack {
					Label(.localized("Check All Certificates Now"), systemImage: "checkmark.shield")
					Spacer()
					if _isCheckingAll { ProgressView() }
				}
			}
			.disabled(_isCheckingAll)
		} header: {
			Text(.localized("Certificates & Revocation"))
		} footer: {
			Text(.localized("Odysseus asks Apple's OCSP responder whether each certificate is still valid. A revoked certificate can come back as valid too, so statuses are re-checked both ways."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Installing
	private var _installing: some View {
		Section {
			NavigationLink {
				InstallationView()
					.odPageBackground()
			} label: {
				HStack {
					Label(.localized("Install Method"), systemImage: "arrow.down.app")
					Spacer()
					Text(_installMethod == 1 ? String.localized("Pairing (LocalDevVPN)") : String.localized("Local Server"))
						.foregroundStyle(.secondary)
				}
			}
			VStack(alignment: .leading, spacing: 6) {
				Text(.localized("Custom Plist Server"))
				TextField("https://api.palera.in/genPlist", text: $_plistServer)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
					.foregroundStyle(.secondary)
			}
			Toggle(.localized("Delete IPA After Signing"), isOn: $_autoDelete)
		} header: {
			Text(.localized("Installing"))
		} footer: {
			Text(.localized("The plist server is only used by the Local Server method in semi-local mode. Leave it empty for the default."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Sources
	private var _sources: some View {
		Section {
			Picker(.localized("Refresh Sources"), selection: $_sourceRefreshHours) {
				Text(.localized("Manually")).tag(0)
				Text(.localized("Every Hour")).tag(1)
				Text(.localized("Every 6 Hours")).tag(6)
				Text(.localized("Daily")).tag(24)
			}
			Toggle(.localized("Combine Duplicate Apps"), isOn: $_combineDuplicates)
			NavigationLink {
				ODDiscoverLayoutView()
			} label: {
				Label(.localized("Discover Layout"), systemImage: "rectangle.3.group")
			}
			NavigationLink {
				ODSourceListTransferView()
			} label: {
				Label(.localized("Export / Import Sources"), systemImage: "arrow.up.arrow.down")
			}
		} header: {
			Text(.localized("Sources & Discover"))
		} footer: {
			Text(.localized("Combining shows an app once when several sources have the same bundle ID."))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Appearance
	private var _appearance: some View {
		Section {
			NavigationLink {
				AppearanceView()
					.odPageBackground()
			} label: {
				Label(.localized("Theme & Accent"), systemImage: "paintpalette")
			}
		} header: {
			Text(.localized("Appearance"))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: Storage
	private var _storage: some View {
		Section {
			NavigationLink {
				ArchiveView()
					.odPageBackground()
			} label: {
				Label(.localized("Archive & Compression"), systemImage: "archivebox")
			}
			Button {
				ResetView.clearWorkCache()
				ResetView.clearNetworkCache()
				FRIconCache.shared.invalidateAll()
				ODTheme.success()
				_cacheCleared = true
			} label: {
				HStack {
					Label(.localized("Clear Cache"), systemImage: "sparkles")
					Spacer()
					if _cacheCleared {
						Image(systemName: "checkmark").foregroundStyle(ODTheme.valid)
					}
				}
			}
			Button {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			} label: {
				Label(.localized("Open in Files"), systemImage: "folder")
			}
			NavigationLink {
				ODDiagnosticsView()
			} label: {
				Label(.localized("Diagnostics & Logs"), systemImage: "stethoscope")
			}
			NavigationLink {
				ResetView()
					.odPageBackground()
			} label: {
				Label(.localized("Reset"), systemImage: "trash")
					.foregroundStyle(ODTheme.revoked)
			}
		} header: {
			Text(.localized("Storage & Diagnostics"))
		}
		.listRowBackground(ODTheme.navy)
	}

	// MARK: About
	private var _about: some View {
		Section {
			NavigationLink {
				AboutView()
					.odPageBackground()
			} label: {
				Label(.localized("About & Credits"), systemImage: "info.circle")
			}
		} footer: {
			Text(verbatim: "Odysseus is free software under the GPL-3.0. Based on Feather by Samara and FreeSign by Frizzle. Apple ID signing uses SideSign from SideStore (AGPL-3.0).")
		}
		.listRowBackground(ODTheme.navy)
	}
}

// MARK: - Bundle ID prefix / suffix
struct ODBundleIDView: View {
	@Binding var prefix: String
	@Binding var suffix: String

	var body: some View {
		List {
			Section {
				TextField(.localized("Prefix, e.g. com.me"), text: $prefix)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				TextField(.localized("Suffix, e.g. odysseus"), text: $suffix)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
			} footer: {
				Text(verbatim: .localized("Example: %@", arguments: ODPrefs.adjustedBundleID("com.example.app")))
			}
			.listRowBackground(ODTheme.navy)
		}
		.odPageBackground()
		.navigationTitle(.localized("Bundle ID"))
	}
}

// MARK: - Discover layout
struct ODDiscoverLayoutView: View {
	@State private var _rows: [ODPrefs.DiscoverRow] = ODPrefs.discoverOrder
	@State private var _hidden: Set<String> = ODPrefs.hiddenSourceIDs

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)]
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		List {
			Section {
				ForEach(_rows) { row in
					Label(row.title, systemImage: "line.3.horizontal")
				}
				.onMove { from, to in
					_rows.move(fromOffsets: from, toOffset: to)
					ODPrefs.setDiscoverOrder(_rows)
				}
				Button(.localized("Reset Order")) {
					_rows = ODPrefs.DiscoverRow.defaultOrder
					ODPrefs.setDiscoverOrder(_rows)
				}
			} header: {
				Text(.localized("Row Order"))
			} footer: {
				Text(.localized("Drag to reorder."))
			}
			.listRowBackground(ODTheme.navy)

			Section {
				ForEach(_sources, id: \.objectID) { source in
					let id = source.identifier ?? ""
					Toggle(isOn: Binding(
						get: { !_hidden.contains(id) },
						set: { show in
							if show { _hidden.remove(id) } else { _hidden.insert(id) }
							ODPrefs.hiddenSourceIDs = _hidden
						}
					)) {
						Text(source.name ?? source.sourceURL?.host ?? id)
					}
				}
			} header: {
				Text(.localized("Show on Discover"))
			} footer: {
				Text(.localized("Hidden sources stay in Sources, they just don't appear on Discover."))
			}
			.listRowBackground(ODTheme.navy)
		}
		.environment(\.editMode, .constant(.active))
		.odPageBackground()
		.navigationTitle(.localized("Discover Layout"))
	}
}

// MARK: - Export / import sources
struct ODSourceListTransferView: View {
	@State private var _importText = ""
	@State private var _status: String?

	var body: some View {
		List {
			Section {
				Button(.localized("Share Source List"), systemImage: "square.and.arrow.up") {
					let text = _exportText()
					guard !text.isEmpty else { return }
					let url = FileManager.default.temporaryDirectory.appendingPathComponent("Odysseus Sources.txt")
					try? text.write(to: url, atomically: true, encoding: .utf8)
					UIActivityViewController.show(activityItems: [url])
				}
				Button(.localized("Copy Source List"), systemImage: "doc.on.doc") {
					UIPasteboard.general.string = _exportText()
					_status = .localized("Copied.")
				}
			} header: {
				Text(.localized("Export"))
			} footer: {
				Text(.localized("One source URL per line."))
			}
			.listRowBackground(ODTheme.navy)

			Section {
				TextField(.localized("Paste URLs, one per line"), text: $_importText, axis: .vertical)
					.lineLimit(4...12)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Button(.localized("Paste from Clipboard"), systemImage: "doc.on.clipboard") {
					_importText = UIPasteboard.general.string ?? ""
				}
				Button(.localized("Add Sources"), systemImage: "plus.circle") {
					_import()
				}
				.disabled(_importText.isEmpty)
			} header: {
				Text(.localized("Import"))
			} footer: {
				if let _status { Text(_status) }
			}
			.listRowBackground(ODTheme.navy)
		}
		.odPageBackground()
		.navigationTitle(.localized("Source List"))
	}

	private func _exportText() -> String {
		Storage.shared.getSources()
			.compactMap { $0.sourceURL?.absoluteString }
			.joined(separator: "\n")
	}

	private func _import() {
		let urls = _importText
			.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "," })
			.compactMap { DefaultSourceInstaller.validURL(String($0)) }
		let existing = Set(Storage.shared.getSources().compactMap { $0.sourceURL?.absoluteString })
		var added = 0
		for url in urls where !existing.contains(url.absoluteString) && !Storage.shared.sourceExists(url.absoluteString) {
			Storage.shared.addSource(url, name: url.host, identifier: url.absoluteString, deferSave: true) { error in
				if error == nil { added += 1 }
			}
		}
		try? Storage.shared.context.save()
		_status = .localized("Added %lld sources.", arguments: added)
		_importText = ""
		Task { await ODCatalogStore.shared.load(force: false) }
	}
}
