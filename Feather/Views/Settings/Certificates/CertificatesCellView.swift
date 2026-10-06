//
//  CertificateCellView.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesCellView: View {
	@State var data: Certificate?
	
	@ObservedObject var cert: CertificatePair
	@ObservedObject private var _statusStore = ODCertificateStatusStore.shared
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 6) {
			let title = {
				var title = cert.nickname ?? data?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = data?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				return title
			}()
			
			NBTitleWithSubtitleView(
				title: title,
				subtitle: data?.AppIDName ?? .localized("Unknown")
			)
			
			_certInfoPill(data: cert)
		}
		.frame(height: 80)
		.contentTransition(.opacity)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onAppear {
			withAnimation {
				data = Storage.shared.getProvisionFileDecoded(for: cert)
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesCellView {
	@ViewBuilder
	private func _certInfoPill(data: CertificatePair) -> some View {
		let pillItems = _buildPills(from: data)
		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]
				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count
				)
			}
		}
	}
	
	private func _buildPills(from cert: CertificatePair) -> [NBPillItem] {
		var pills: [NBPillItem] = []
		
		if cert.ppQCheck == true {
			pills.append(NBPillItem(title: .localized("PPQCheck"), icon: "checkmark.shield", color: .red))
		}
		
		// Odysseus: live OCSP status instead of the one-way revoked flag.
		if let result = _statusStore.result(for: cert) {
			pills.append(NBPillItem(
				title: result.title,
				icon: result.icon,
				color: ODOCSPPill.color(for: result.status)
			))
		}
		
		if let expiration = cert.expiration, _statusStore.result(for: cert)?.status != .revoked {
			let info = expiration.expirationInfo()
			let warningDays = UserDefaults.standard.integer(forKey: ODPrefs.expiryWarningDays)
			let isWarning = expiration.timeIntervalSinceNow < Double(max(warningDays, 1)) * 86_400
			pills.append(NBPillItem(
				title: expiration.timeIntervalSinceNow <= 0 ? .localized("Expired") : info.formatted,
				icon: "clock.fill",
				color: isWarning ? ODTheme.revoked : ODTheme.valid
			))
		}
		
		return pills
	}
}
