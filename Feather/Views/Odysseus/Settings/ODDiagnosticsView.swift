//
//  ODDiagnosticsView.swift
//  Odysseus
//
//  What's set up, what's reachable, and a log export for bug reports.
//

import SwiftUI
import OSLog
import IDeviceSwift

struct ODDiagnosticsView: View {
	@ObservedObject private var _appleID = ODAppleIDManager.shared
	@State private var _checks: [String: Bool?] = [:]
	@State private var _isExporting = false

	private var _hasPairing: Bool {
		FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile())
	}

	var body: some View {
		List {
			Section {
				_row(.localized("App"), "Odysseus \(Bundle.main.version)")
				_row(.localized("Bundle ID"), Bundle.main.bundleIdentifier ?? "")
				_row(.localized("Device"), MobileGestalt().getStringForName("PhysicalHardwareNameString") ?? UIDevice.current.model)
				_row(.localized("iOS"), UIDevice.current.systemVersion)
			} header: {
				Text(.localized("This Device"))
			}
			.listRowBackground(ODTheme.navy)

			Section {
				_row(.localized("Install Method"), UserDefaults.standard.integer(forKey: ODPrefs.installationMethod) == 1 ? "Pairing" : "Local Server")
				_row(.localized("Pairing File"), _hasPairing ? String.localized("Present") : String.localized("Missing"))
				_row(.localized("UDID"), _appleID.deviceUDID == nil ? String.localized("Unknown") : String.localized("Known"))
				_row(.localized("Certificates"), Storage.shared.countContent(for: CertificatePair.self))
				_row(.localized("Sources"), Storage.shared.countContent(for: AltSource.self))
				_row(.localized("Signed Apps"), Storage.shared.countContent(for: Signed.self))
				_row(.localized("Apple ID"), _appleID.isSignedIn ? String.localized("Signed in") : String.localized("Signed out"))
			} header: {
				Text(.localized("Setup"))
			}
			.listRowBackground(ODTheme.navy)

			Section {
				_reachability(.localized("Apple OCSP"), "http://ocsp.apple.com")
				_reachability(.localized("Apple Developer"), "https://developerservices2.apple.com")
				_reachability(.localized("Anisette Server"), _appleID.anisetteServers.first?.absoluteString ?? ODAppleIDManager.defaultAnisetteServer)
				Button(.localized("Run Checks"), systemImage: "bolt.horizontal") {
					Task { await _runChecks() }
				}
			} header: {
				Text(.localized("Network"))
			}
			.listRowBackground(ODTheme.navy)

			Section {
				Button {
					Task { await _exportLogs() }
				} label: {
					HStack {
						Label(.localized("Export Logs"), systemImage: "doc.text")
						Spacer()
						if _isExporting { ProgressView() }
					}
				}
				.disabled(_isExporting)
			} footer: {
				Text(.localized("Saves this session's logs to a text file you can share. Logs don't include passwords or certificate files."))
			}
			.listRowBackground(ODTheme.navy)
		}
		.odPageBackground()
		.navigationTitle(.localized("Diagnostics"))
		.task { await _runChecks() }
	}

	private func _row(_ title: String, _ value: String) -> some View {
		HStack {
			Text(title)
			Spacer()
			Text(value)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.textSelection(.enabled)
		}
	}

	private func _reachability(_ title: String, _ url: String) -> some View {
		HStack {
			Text(title)
			Spacer()
			switch _checks[url] {
			case .some(.some(true)):
				Image(systemName: "checkmark.circle.fill").foregroundStyle(ODTheme.valid)
			case .some(.some(false)):
				Image(systemName: "xmark.circle.fill").foregroundStyle(ODTheme.revoked)
			case .some(.none):
				ProgressView()
			case .none:
				Image(systemName: "minus.circle").foregroundStyle(.secondary)
			}
		}
	}

	private func _runChecks() async {
		let urls = [
			"http://ocsp.apple.com",
			"https://developerservices2.apple.com",
			_appleID.anisetteServers.first?.absoluteString ?? ODAppleIDManager.defaultAnisetteServer
		]
		for url in urls {
			_checks[url] = .some(nil)
		}
		for url in urls {
			guard let target = URL(string: url) else { continue }
			var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
			request.httpMethod = "HEAD"
			let reachable: Bool
			if let (_, response) = try? await URLSession.shared.data(for: request), response is HTTPURLResponse {
				reachable = true
			} else {
				reachable = false
			}
			_checks[url] = .some(reachable)
		}
	}

	private func _exportLogs() async {
		_isExporting = true
		defer { _isExporting = false }

		let header = "Odysseus \(Bundle.main.version) — iOS \(UIDevice.current.systemVersion)"
		let text: String = await Task.detached(priority: .userInitiated) {
			var lines: [String] = [
				header,
				"Exported \(Date())",
				""
			]
			if let store = try? OSLogStore(scope: .currentProcessIdentifier) {
				let position = store.position(date: Date().addingTimeInterval(-3600 * 6))
				let formatter = ISO8601DateFormatter()
				if let entries = try? store.getEntries(at: position) {
					for case let entry as OSLogEntryLog in entries where entry.subsystem.hasPrefix("com.mirazbakis") || entry.subsystem.hasPrefix("idevice") {
						lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
					}
				}
			}
			return lines.joined(separator: "\n")
		}.value

		let url = FileManager.default.temporaryDirectory.appendingPathComponent("Odysseus-log.txt")
		do {
			try text.write(to: url, atomically: true, encoding: .utf8)
			UIActivityViewController.show(activityItems: [url])
		} catch {
			UIAlertController.showAlertWithOk(title: .localized("Couldn't export"), message: error.localizedDescription)
		}
	}
}
