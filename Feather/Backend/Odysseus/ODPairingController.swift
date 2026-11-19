//
//  ODPairingController.swift
//  Odysseus
//
//  On-device pairing (iOS 27+). Odysseus advertises itself as a pairable
//  host; the user taps "Pair with Odysseus" in Settings › Privacy &
//  Security › Developer Mode and types the PIN Odysseus shows. The result
//  is the device's UDID (used for Apple ID signing) and a RemotePairing
//  file that can be used for installing over LocalDevVPN.
//

import Foundation
import UIKit
import AVFoundation
import UserNotifications
import IDeviceSwift
import OSLog

@MainActor
final class ODPairingController: ObservableObject {
	static let shared = ODPairingController()

	/// UDID reported by the device when it paired with Odysseus.
	static let pairedUDIDKey = "Odysseus.pairedDeviceUDID"
	static let pairedNameKey = "Odysseus.pairedDeviceName"
	static let hostName = "Odysseus"

	enum Phase: Equatable {
		case idle
		case waiting
		case showPin(String)
		case success(udid: String, name: String)
		case failed(String)
	}

	@Published private(set) var phase: Phase = .idle
	/// Set after pairing when a pairing file already existed, so the user
	/// can choose to replace it.
	@Published private(set) var hasNewPairingFile = false

	static var isSupported: Bool {
		if #available(iOS 27, *) { return true }
		return false
	}

	var isRunning: Bool {
		switch phase {
		case .waiting, .showPin: return true
		default: return false
		}
	}

	static var pairedUDID: String? {
		let value = UserDefaults.standard.string(forKey: pairedUDIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
		return (value?.isEmpty ?? true) ? nil : value
	}

	private var _host: PairableHost?
	private var _service: NetService?
	private var _backgroundTask: UIBackgroundTaskIdentifier = .invalid
	private let _audio = AVAudioEngine()
	private var _audioRunning = false

	private static var _rpFileURL: URL {
		let dir = URL.applicationSupportDirectory.appendingPathComponent("Odysseus", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("rp_pairing_file.plist")
	}

	private init() {}

	// MARK: Start / cancel
	func start() {
		guard Self.isSupported, !isRunning else { return }
		phase = .waiting
		hasNewPairingFile = false

		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
		_startKeepAlive()

		let host = PairableHost(name: Self.hostName)
		_host = host
		let fileURL = Self._rpFileURL.deletingLastPathComponent().appendingPathComponent("rp_pairing_file.new.plist")

		Thread.detachNewThread { [weak self] in
			let outcome: Swift.Result<PairableHost.Result, Error>
			do {
				let result = try host.run(
					pairingFileURL: fileURL,
					onReady: { ad in
						DispatchQueue.main.async { self?._advertise(ad) }
					},
					onPin: { pin in
						DispatchQueue.main.async { self?._showPin(pin) }
					}
				)
				outcome = .success(result)
			} catch {
				outcome = .failure(error)
			}
			DispatchQueue.main.async { self?._finish(outcome) }
		}
	}

	func cancel() {
		_host?.cancel()
	}

	func reset() {
		guard !isRunning else { return }
		phase = .idle
	}

	/// Replaces the pairing file Odysseus installs with by the one just made.
	func useNewPairingFile() {
		FR.movePairing(Self._rpFileURL)
		hasNewPairingFile = false
	}

	// MARK: Steps
	private func _advertise(_ ad: PairableHost.Advertisement) {
		_service?.stop()
		let service = NetService(domain: "local.", type: PairableHost.serviceType, name: ad.serviceID, port: ad.port)
		service.setTXTRecord(NetService.data(fromTXTRecord: ad.txtRecord))
		service.publish()
		_service = service
		Logger.misc.info("Advertising as a pairable host on port \(ad.port)")
	}

	private func _showPin(_ pin: String) {
		phase = .showPin(pin)
		_notify(
			id: "odysseus.pairing.pin",
			title: .localized("Odysseus pairing code"),
			body: .localized("Enter %@ on this device to pair.", arguments: pin)
		)
	}

	private func _finish(_ outcome: Swift.Result<PairableHost.Result, Error>) {
		_service?.stop()
		_service = nil
		_host = nil
		_stopKeepAlive()
		UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["odysseus.pairing.pin"])

		switch outcome {
		case .failure(let error):
			if case PairableHost.Failure.cancelled = error {
				phase = .idle
			} else {
				phase = .failed(error.localizedDescription)
			}
		case .success(let result):
			let defaults = UserDefaults.standard
			if !result.udid.isEmpty {
				defaults.set(result.udid, forKey: Self.pairedUDIDKey)
			}
			defaults.set(result.deviceName, forKey: Self.pairedNameKey)

			// Keep the RemotePairing file next to Odysseus's data.
			let saved = Self._rpFileURL
			try? FileManager.default.removeItem(at: saved)
			try? FileManager.default.moveItem(at: result.pairingFileURL, to: saved)

			// Use it for installing right away if there's no pairing file yet.
			if FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) {
				hasNewPairingFile = true
			} else {
				FR.movePairing(saved)
			}

			phase = .success(udid: result.udid, name: result.deviceName)
			_notify(
				id: "odysseus.pairing.done",
				title: .localized("Pairing complete"),
				body: .localized("Return to Odysseus to finish.")
			)
		}
	}

	// MARK: Keep alive
	/// Keeps Odysseus running while the user is in Settings: a background
	/// task plus silent audio (the app already has the audio background mode).
	private func _startKeepAlive() {
		if _backgroundTask == .invalid {
			_backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Odysseus pairing") { [weak self] in
				Task { @MainActor in self?._endBackgroundTask() }
			}
		}
		guard !_audioRunning else { return }
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)
			let silence = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
				for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
					memset(buffer.mData, 0, Int(buffer.mDataByteSize))
				}
				return noErr
			}
			_audio.attach(silence)
			_audio.connect(silence, to: _audio.mainMixerNode, format: nil)
			try _audio.start()
			_audioRunning = true
		} catch {
			Logger.misc.error("Couldn't start keep-alive audio: \(error.localizedDescription)")
		}
	}

	private func _stopKeepAlive() {
		if _audioRunning {
			_audio.stop()
			for node in _audio.attachedNodes where node is AVAudioSourceNode {
				_audio.detach(node)
			}
			_audioRunning = false
		}
		_endBackgroundTask()
	}

	private func _endBackgroundTask() {
		guard _backgroundTask != .invalid else { return }
		UIApplication.shared.endBackgroundTask(_backgroundTask)
		_backgroundTask = .invalid
	}

	private func _notify(id: String, title: String, body: String) {
		let content = UNMutableNotificationContent()
		content.title = title
		content.body = body
		content.sound = .default
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
	}
}
