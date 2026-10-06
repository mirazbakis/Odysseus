//
//  ODLibraryView.swift
//  Odysseus
//
//  Your certificate (with its live OCSP status) on top, then Signed,
//  Downloaded and Imported apps with expiry pills.
//

import SwiftUI
import CoreData
import NimbleViews

struct ODLibraryView: View {
	@StateObject private var _downloadManager = DownloadManager.shared
	@ObservedObject private var _statusStore = ODCertificateStatusStore.shared
	@ObservedObject private var _appleID = ODAppleIDManager.shared

	@AppStorage(ODPrefs.defaultCertificate) private var _selectedCertIndex: Int = 0

	@State private var _searchText = ""
	@State private var _scope: Scope = .all
	@State private var _infoApp: AnyApp?
	@State private var _signingApp: AnyApp?
	@State private var _installApp: AnyApp?
	@State private var _isImporting = false
	@State private var _isImportingURL = false
	@State private var _importURL = ""
	@State private var _isAddingCertificate = false
	@State private var _workingUUIDs: Set<String> = []

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signed: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _imported: FetchedResults<Imported>

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>

	enum Scope: String, CaseIterable, Identifiable {
		case all, signed, downloaded, imported
		var id: String { rawValue }
		var title: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .downloaded: return .localized("Downloaded")
			case .imported: return .localized("Imported")
			}
		}
	}

	private func _matches(_ app: AppInfoPresentable) -> Bool {
		_searchText.isEmpty
			|| (app.name?.localizedCaseInsensitiveContains(_searchText) ?? false)
			|| (app.identifier?.localizedCaseInsensitiveContains(_searchText) ?? false)
	}

	private var _signedApps: [Signed] { _signed.filter { _matches($0) } }
	private var _downloadedApps: [Imported] { _imported.filter { ODDownloadOrigin.isDownloaded($0.uuid) && _matches($0) } }
	private var _importedApps: [Imported] { _imported.filter { !ODDownloadOrigin.isDownloaded($0.uuid) && _matches($0) } }

	private var _selectedCert: CertificatePair? {
		_certificates.indices.contains(_selectedCertIndex) ? _certificates[_selectedCertIndex] : _certificates.first
	}

	var body: some View {
		NavigationStack {
			List {
				if _searchText.isEmpty {
					Section {
						ODCertificateStatusCard(
							certificate: _selectedCert,
							certificateCount: _certificates.count,
							onAdd: { _isAddingCertificate = true }
						)
						.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
						.listRowBackground(Color.clear)
						.listRowSeparator(.hidden)

						if _appleID.isSignedIn {
							ODAppleIDStatusCard()
								.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
								.listRowBackground(Color.clear)
								.listRowSeparator(.hidden)
						}
					}
				}

				if _scope == .all || _scope == .signed, !_signedApps.isEmpty {
					Section {
						ForEach(_signedApps, id: \.objectID) { app in
							_row(app)
						}
					} header: {
						_header(.localized("Signed"), count: _signedApps.count)
					}
				}

				if _scope == .all || _scope == .downloaded, !_downloadedApps.isEmpty {
					Section {
						ForEach(_downloadedApps, id: \.objectID) { app in
							_row(app)
						}
					} header: {
						_header(.localized("Downloaded"), count: _downloadedApps.count)
					}
				}

				if _scope == .all || _scope == .imported, !_importedApps.isEmpty {
					Section {
						ForEach(_importedApps, id: \.objectID) { app in
							_row(app)
						}
					} header: {
						_header(.localized("Imported"), count: _importedApps.count)
					}
				}

				if _signed.isEmpty && _imported.isEmpty {
					Section {
						ODEmptyStateView(
							systemImage: "shippingbox",
							title: .localized("No apps yet"),
							message: .localized("Get apps on Discover, or import an .ipa from Files or a link.")
						)
						.frame(minHeight: 220)
						.listRowBackground(Color.clear)
					}
				}
			}
			.listStyle(.insetGrouped)
			.odPageBackground()
			.navigationTitle(.localized("Library"))
			.searchable(text: $_searchText, prompt: Text(.localized("Search your apps")))
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Menu {
						Picker(.localized("Show"), selection: $_scope) {
							ForEach(Scope.allCases) { scope in
								Text(scope.title).tag(scope)
							}
						}
					} label: {
						Image(systemName: _scope == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
					}
				}
				ToolbarItem(placement: .topBarTrailing) {
					Menu {
						Button(.localized("Import from Files"), systemImage: "folder") { _isImporting = true }
						Button(.localized("Import from Link"), systemImage: "link") { _isImportingURL = true }
						Divider()
						Button(.localized("Add Certificate"), systemImage: "person.text.rectangle") { _isAddingCertificate = true }
					} label: {
						Image(systemName: "plus")
					}
				}
			}
			.sheet(item: $_infoApp) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_installApp) { app in
				ODInstallSheet(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(320)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_signingApp) { app in
				SigningView(app: app.base)
			}
			.sheet(isPresented: $_isAddingCertificate) {
				CertificatesAddView()
					.presentationDetents([.medium, .large])
			}
			.sheet(isPresented: $_isImporting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						for url in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
							let download = _downloadManager.startArchive(from: url, id: id)
							try? _downloadManager.handlePachageFile(url: url, dl: download)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(.localized("Import from Link"), isPresented: $_isImportingURL) {
				TextField(.localized("https://example.com/app.ipa"), text: $_importURL)
					.textInputAutocapitalization(.never)
					.keyboardType(.URL)
				Button(.localized("Cancel"), role: .cancel) { _importURL = "" }
				Button(.localized("Download")) {
					if let url = URL(string: _importURL) {
						_ = _downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
					_importURL = ""
				}
			} message: {
				Text(.localized("Paste a direct link to an .ipa file."))
			}
		}
	}

	// MARK: Header
	private func _header(_ title: String, count: Int) -> some View {
		HStack {
			Text(title)
			Spacer()
			Text(verbatim: "\(count)")
				.foregroundStyle(.secondary)
		}
	}

	// MARK: Row
	@ViewBuilder
	private func _row(_ app: AppInfoPresentable) -> some View {
		let uuid = app.uuid ?? ""
		HStack(spacing: 14) {
			FRAppIconView(app: app, size: 54)

			VStack(alignment: .leading, spacing: 3) {
				Text(app.name ?? .localized("Unknown"))
					.font(.system(.body, design: .rounded).weight(.semibold))
					.foregroundStyle(.white)
					.lineLimit(1)
				Text(verbatim: [app.version, app.identifier].compactMap { $0 }.joined(separator: " · "))
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				if app.isSigned {
					_signedPills(app)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			if _workingUUIDs.contains(uuid) {
				ProgressView()
					.controlSize(.small)
			} else {
				Button {
					ODTheme.lightImpact()
					if app.isSigned {
						_installApp = AnyApp(base: app)
					} else {
						_signAndInstall(app)
					}
				} label: {
					Text(app.isSigned ? String.localized("Install") : String.localized("Get"))
						.textCase(.uppercase)
				}
				.buttonStyle(ODCapsuleButtonStyle(filled: !app.isSigned))
			}
		}
		.padding(.vertical, 4)
		.listRowBackground(ODTheme.navy)
		.contextMenu { _menu(app) }
		.swipeActions {
			Button(role: .destructive) {
				Storage.shared.deleteApp(for: app)
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}
		}
	}

	@ViewBuilder
	private func _signedPills(_ app: AppInfoPresentable) -> some View {
		let cert = Storage.shared.getCertificate(from: app)
		let appleIDInfo = ODAppleIDSignedApps.shared.info(for: app.uuid)
		HStack(spacing: 6) {
			if let appleIDInfo {
				ODExpiryPill(expiration: appleIDInfo.expiration)
				ODPill(text: .localized("Apple ID"), color: Color.accentColor, icon: "person.crop.circle.fill")
			} else if let cert {
				let status = _statusStore.result(for: cert)
				ODExpiryPill(expiration: cert.expiration, revoked: status?.status == .revoked)
				if let status, status.status != .valid, status.status != .revoked {
					ODOCSPPill(result: status, compact: true)
				}
			}
		}
	}

	@ViewBuilder
	private func _menu(_ app: AppInfoPresentable) -> some View {
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "arrow.up.forward.app") {
					UIApplication.openApp(with: id)
				}
			}
			Button(.localized("Install"), systemImage: "arrow.down.circle") {
				_installApp = AnyApp(base: app)
			}
			Button(.localized("Sign Again…"), systemImage: "signature") {
				_signingApp = AnyApp(base: app)
			}
			Button(.localized("Save a Copy"), systemImage: "square.and.arrow.up") {
				_installApp = AnyApp(base: app, archive: true)
			}
		} else {
			Button(.localized("Sign & Install"), systemImage: "arrow.down.circle") {
				_signAndInstall(app)
			}
			Button(.localized("Customize & Sign…"), systemImage: "slider.horizontal.3") {
				_signingApp = AnyApp(base: app)
			}
			if _appleID.isSignedIn, !_certificates.isEmpty {
				Menu(.localized("Sign With")) {
					Button(.localized("Apple ID"), systemImage: "person.crop.circle") {
						_signAndInstall(app, identity: .appleID)
					}
					Button(.localized("Default Certificate"), systemImage: "person.text.rectangle") {
						_signAndInstall(app, identity: .certificate(_selectedCert))
					}
				}
			}
		}
		Button(.localized("Get Info"), systemImage: "info.circle") {
			_infoApp = AnyApp(base: app)
		}
		Divider()
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteApp(for: app)
		}
	}

	private func _signAndInstall(_ app: AppInfoPresentable, identity: ODSigningIdentity? = nil) {
		guard let uuid = app.uuid else { return }
		_workingUUIDs.insert(uuid)
		Task { @MainActor in
			_ = await ODSignPipeline.shared.signAndInstall(app, identity: identity)
			_workingUUIDs.remove(uuid)
		}
	}
}
