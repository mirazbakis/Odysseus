//
//  ODCertificateCards.swift
//  Odysseus
//
//  Certificate status card (expiry + live OCSP status + Check Now)
//  and the matching card for the Apple ID certificate.
//

import SwiftUI

// MARK: - OCSP pill
struct ODOCSPPill: View {
	let result: ODOCSPResult?
	var compact: Bool = false

	var body: some View {
		if let result {
			ODPill(text: compact ? result.title : _longTitle(result), color: Self.color(for: result.status), icon: result.icon)
		} else {
			ODPill(text: .localized("Not checked"), color: ODTheme.unknown, icon: "questionmark.circle.fill")
		}
	}

	private func _longTitle(_ result: ODOCSPResult) -> String {
		switch result.status {
		case .revoked:
			if let date = result.revokedAt {
				return .localized("Revoked %@", arguments: DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none))
			}
			return result.title
		default:
			return result.title
		}
	}

	static func color(for status: ODOCSPResult.Status) -> Color {
		switch status {
		case .valid: return ODTheme.valid
		case .revoked: return ODTheme.revoked
		case .unknown: return ODTheme.unknown
		case .couldntCheck: return ODTheme.couldntCheck
		}
	}
}

// MARK: - Certificate card
struct ODCertificateStatusCard: View {
	let certificate: CertificatePair?
	let certificateCount: Int
	var onAdd: () -> Void

	@ObservedObject private var _store = ODCertificateStatusStore.shared
	@State private var _decoded: Certificate?
	@State private var _showDetails = false

	var body: some View {
		if let certificate {
			_card(for: certificate)
				.task(id: certificate.uuid) {
					_decoded = Storage.shared.getProvisionFileDecoded(for: certificate)
					if _store.result(for: certificate) == nil {
						await _store.check(certificate)
					}
				}
				.sheet(isPresented: $_showDetails) {
					ODOCSPDetailsSheet(certificate: certificate)
						.presentationDetents([.medium, .large])
				}
		} else {
			_emptyCard
		}
	}

	private func _card(for certificate: CertificatePair) -> some View {
		let result = _store.result(for: certificate)
		let isChecking = _store.isChecking(certificate)

		return VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Image(systemName: "person.text.rectangle.fill")
					.font(.title2)
					.foregroundStyle(Color.accentColor)
					.frame(width: 44, height: 44)
					.background(Circle().fill(Color.accentColor.opacity(0.12)))

				VStack(alignment: .leading, spacing: 2) {
					Text(certificate.nickname ?? _decoded?.Name ?? .localized("Certificate"))
						.font(.system(.headline, design: .rounded).weight(.bold))
						.foregroundStyle(.white)
						.lineLimit(1)
					Text(_decoded?.TeamName ?? .localized("Signing certificate"))
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer()
				NavigationLink {
					CertificatesView()
						.odPageBackground()
				} label: {
					Text(certificateCount > 1 ? String.localized("Switch") : String.localized("Manage"))
						.font(.subheadline.weight(.semibold))
				}
				.buttonStyle(.borderless)
			}

			HStack(spacing: 6) {
				ODExpiryPill(expiration: certificate.expiration)
				if isChecking {
					ODPill(text: .localized("Checking…"), color: ODTheme.unknown, icon: "arrow.triangle.2.circlepath")
				} else {
					ODOCSPPill(result: result)
				}
			}

			HStack {
				Group {
					if let result {
						Text(verbatim: .localized("Checked %@", arguments: RelativeDateTimeFormatter().localizedString(for: result.checkedAt, relativeTo: Date())))
					} else {
						Text(.localized("Revocation not checked yet"))
					}
				}
				.font(.caption)
				.foregroundStyle(.secondary)

				Spacer()

				Button {
					_showDetails = true
				} label: {
					Image(systemName: "info.circle")
				}
				.buttonStyle(.borderless)

				Button {
					ODTheme.lightImpact()
					Task { await _store.check(certificate) }
				} label: {
					Text(.localized("Check Now"))
						.font(.caption.weight(.bold))
						.padding(.horizontal, 12)
						.padding(.vertical, 6)
						.odGlassCapsule(tint: Color.accentColor.opacity(0.25))
				}
				.buttonStyle(.plain)
				.disabled(isChecking)
			}

			if result?.status == .revoked {
				Label {
					Text(_revokedMessage(result))
						.font(.caption)
				} icon: {
					Image(systemName: "exclamationmark.octagon.fill")
				}
				.foregroundStyle(ODTheme.revoked)
			}
		}
		.odCard()
	}

	private func _revokedMessage(_ result: ODOCSPResult?) -> String {
		var parts: [String] = [.localized("Apple revoked this certificate. Apps signed with it won't open.")]
		if let reason = result?.reasonName {
			parts.append(.localized("Reason: %@.", arguments: reason))
		}
		return parts.joined(separator: " ")
	}

	private var _emptyCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 12) {
				Image(systemName: "person.text.rectangle")
					.font(.title2)
					.foregroundStyle(.secondary)
				VStack(alignment: .leading, spacing: 2) {
					Text(.localized("No certificate"))
						.font(.system(.headline, design: .rounded).weight(.bold))
						.foregroundStyle(.white)
					Text(.localized("Import your .p12 and .mobileprovision, or sign in with your Apple ID in Settings."))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Button(.localized("Add Certificate"), action: onAdd)
				.buttonStyle(ODCapsuleButtonStyle(filled: true))
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.odCard()
	}
}

// MARK: - Apple ID card
struct ODAppleIDStatusCard: View {
	@ObservedObject private var _manager = ODAppleIDManager.shared
	@ObservedObject private var _store = ODCertificateStatusStore.shared

	var body: some View {
		let result = _store.results[ODCertificateStatusStore.appleIDKey]
		let isChecking = _store.checking.contains(ODCertificateStatusStore.appleIDKey)

		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Image(systemName: "person.crop.circle.fill")
					.font(.title2)
					.foregroundStyle(Color.accentColor)
					.frame(width: 44, height: 44)
					.background(Circle().fill(Color.accentColor.opacity(0.12)))
				VStack(alignment: .leading, spacing: 2) {
					Text(_manager.account?.displayName ?? .localized("Apple ID"))
						.font(.system(.headline, design: .rounded).weight(.bold))
						.foregroundStyle(.white)
						.lineLimit(1)
					Text(verbatim: "\(_manager.account?.teamName ?? "") · \(_manager.account?.teamIsFree == true ? String.localized("Free") : String.localized("Paid"))")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer()
				NavigationLink {
					ODAppleIDView()
				} label: {
					Text(.localized("Manage"))
						.font(.subheadline.weight(.semibold))
				}
				.buttonStyle(.borderless)
			}

			HStack(spacing: 6) {
				if _manager.certificate != nil {
					ODExpiryPill(expiration: _manager.certificate?.expiration)
					if isChecking {
						ODPill(text: .localized("Checking…"), color: ODTheme.unknown, icon: "arrow.triangle.2.circlepath")
					} else {
						ODOCSPPill(result: result)
					}
				} else {
					ODPill(text: .localized("No certificate yet"), color: ODTheme.unknown, icon: "person.text.rectangle")
				}
				Spacer()
				if _manager.certificate != nil {
					Button {
						Task { await _manager.checkCertificateStatus(force: true) }
					} label: {
						Text(.localized("Check Now"))
							.font(.caption.weight(.bold))
							.padding(.horizontal, 12)
							.padding(.vertical, 6)
							.odGlassCapsule(tint: Color.accentColor.opacity(0.25))
					}
					.buttonStyle(.plain)
					.disabled(isChecking)
				}
			}
		}
		.odCard()
	}
}

// MARK: - OCSP details
struct ODOCSPDetailsSheet: View {
	let certificate: CertificatePair
	@ObservedObject private var _store = ODCertificateStatusStore.shared
	@Environment(\.dismiss) private var _dismiss

	var body: some View {
		NavigationStack {
			List {
				if let result = _store.result(for: certificate) {
					ODOCSPResultRows(result: result)
				} else {
					Text(.localized("Not checked yet."))
						.listRowBackground(ODTheme.navy)
				}
				Section {
					Button {
						Task { await _store.check(certificate) }
					} label: {
						HStack {
							Label(.localized("Check Now"), systemImage: "arrow.clockwise")
							Spacer()
							if _store.isChecking(certificate) { ProgressView() }
						}
					}
					.listRowBackground(ODTheme.navy)
				}
			}
			.odPageBackground()
			.navigationTitle(.localized("Revocation Status"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Done")) { _dismiss() }
				}
			}
		}
	}
}

struct ODOCSPResultRows: View {
	let result: ODOCSPResult

	var body: some View {
		Section {
			_row(.localized("Status"), result.title, color: ODOCSPPill.color(for: result.status))
			if let date = result.revokedAt {
				_row(.localized("Revoked on"), DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
			}
			if let reason = result.reasonName {
				_row(.localized("Reason"), reason)
			}
			_row(.localized("Last checked"), DateFormatter.localizedString(from: result.checkedAt, dateStyle: .medium, timeStyle: .short))
			if let produced = result.producedAt {
				_row(.localized("Apple's answer from"), DateFormatter.localizedString(from: produced, dateStyle: .medium, timeStyle: .short))
			}
			_row(.localized("Signature"), result.signatureVerified ? String.localized("Verified (Apple)") : String.localized("Not verified"))
			if let url = result.responderURL {
				_row(.localized("Responder"), url)
			}
		} footer: {
			if let detail = result.detail {
				Text(detail)
			}
		}
	}

	private func _row(_ title: String, _ value: String, color: Color = .white) -> some View {
		HStack(alignment: .top) {
			Text(title).foregroundStyle(.secondary)
			Spacer(minLength: 16)
			Text(value)
				.foregroundStyle(color)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)
		}
		.font(.subheadline)
		.listRowBackground(ODTheme.navy)
	}
}
