//
//  ODPairDeviceView.swift
//  Odysseus
//
//  Pairs this device with Odysseus on the device itself (iOS 27+), to get
//  its UDID and a pairing file.
//

import SwiftUI

struct ODPairDeviceView: View {
	@ObservedObject private var _pairing = ODPairingController.shared

	var body: some View {
		List {
			if !ODPairingController.isSupported {
				Section {
					Text(.localized("Pairing on this device needs iOS 27 or later. Import a pairing file or enter the UDID by hand instead."))
						.foregroundStyle(.secondary)
				}
				.listRowBackground(ODTheme.navy)
			} else {
				_statusSection
				_stepsSection
			}
		}
		.navigationTitle(.localized("Pair This Device"))
		.navigationBarTitleDisplayMode(.inline)
		.odPageBackground()
	}

	// MARK: Status
	@ViewBuilder
	private var _statusSection: some View {
		Section {
			switch _pairing.phase {
			case .idle:
				Button(.localized("Start Pairing"), systemImage: "link") {
					_pairing.start()
				}
			case .waiting:
				HStack(spacing: 12) {
					ProgressView()
					Text(.localized("Waiting for this device… Open Settings and tap Pair with Odysseus."))
						.foregroundStyle(.secondary)
				}
				_cancelButton
			case .showPin(let pin):
				VStack(spacing: 8) {
					Text(.localized("Enter this code in Settings"))
						.font(.subheadline)
						.foregroundStyle(.secondary)
					Text(pin)
						.font(.system(size: 46, weight: .bold, design: .monospaced))
						.tracking(6)
						.foregroundStyle(.primary)
						.textSelection(.enabled)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 8)
				_cancelButton
			case .success(let udid, let name):
				Label(.localized("Paired"), systemImage: "checkmark.circle.fill")
					.foregroundStyle(ODTheme.valid)
				if !name.isEmpty {
					LabeledContent(.localized("Device"), value: name)
				}
				LabeledContent(.localized("UDID"), value: udid.isEmpty ? String.localized("Not reported") : udid)
					.font(.system(.footnote, design: .monospaced))
					.textSelection(.enabled)
				if _pairing.hasNewPairingFile {
					Button(.localized("Use New Pairing File for Installing"), systemImage: "arrow.triangle.2.circlepath") {
						_pairing.useNewPairingFile()
					}
				}
				Button(.localized("Done")) { _pairing.reset() }
			case .failed(let message):
				Label(message, systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(ODTheme.revoked)
				Button(.localized("Try Again"), systemImage: "arrow.clockwise") {
					_pairing.reset()
					_pairing.start()
				}
			}
		} footer: {
			if case .success = _pairing.phase, _pairing.hasNewPairingFile {
				Text(.localized("You already had a pairing file, so Odysseus kept it. The UDID is used for Apple ID signing either way."))
			}
		}
		.listRowBackground(ODTheme.navy)
	}

	private var _cancelButton: some View {
		Button(.localized("Cancel"), role: .destructive) {
			_pairing.cancel()
		}
	}

	// MARK: Steps
	private var _stepsSection: some View {
		Section {
			_step(1, .localized("Turn on Developer Mode and stay on Wi-Fi."))
			_step(2, .localized("Tap Start Pairing, then open Settings › Privacy & Security › Developer Mode."))
			_step(3, .localized("Tap Pair with Odysseus at the bottom and type the code Odysseus shows (it also arrives as a notification)."))
			Button(.localized("Open Settings"), systemImage: "gear") {
				if let url = URL(string: UIApplication.openSettingsURLString) {
					UIApplication.shared.open(url)
				}
			}
		} header: {
			Text(.localized("How It Works"))
		} footer: {
			Text(.localized("Odysseus keeps running in the background while you're in Settings. Allow Local Network access when iOS asks."))
		}
		.listRowBackground(ODTheme.navy)
	}

	private func _step(_ number: Int, _ text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Text("\(number)")
				.font(.system(.subheadline, design: .rounded).weight(.bold))
				.foregroundStyle(Color.accentColor)
			Text(text)
				.font(.subheadline)
		}
	}
}
