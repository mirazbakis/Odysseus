//
//  FeatherApp.swift
//  Odysseus (based on Feather by samara, 10.04.2025)
//

import SwiftUI
import Nuke
import IDeviceSwift
import OSLog
import AltSourceKit

@main
struct FeatherApp: App {
	@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
	let heartbeat = HeartbeatManager.shared
	
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject private var _sourceFetchErrorToast = SourceFetchErrorToastCenter.shared
	@Environment(\.scenePhase) private var _scenePhase
	@AppStorage("Feather.userTintColor") private var _tintHex: String = "#B8CCF0"
	let storage = Storage.shared

	var body: some Scene {
		WindowGroup {
			ODRootView()
				.environment(\.managedObjectContext, storage.context)
				.tint(Color(hex: _tintHex))
				.animation(.smooth, value: downloadManager.manualDownloads.description)
				.overlay(alignment: .bottom) {
					if let message = _sourceFetchErrorToast.message {
						SourceFetchErrorToastView(
							message: message,
							systemImage: _sourceFetchErrorToast.systemImage
						)
						.padding(.bottom, 120)
					}
				}
				.animation(.spring(response: 0.28, dampingFraction: 0.9), value: _sourceFetchErrorToast.message)
				.onOpenURL(perform: _handleURL)
				.onReceive(NotificationCenter.default.publisher(for: .heartbeatInvalidHost)) { _ in
					DispatchQueue.main.async {
						UIAlertController.showAlertWithOk(
							title: "InvalidHostID",
							message: .localized("Your pairing file is invalid and is incompatible with your device, please import a valid pairing file.")
						)
					}
				}
				.onAppear {
					let window = UIApplication.topViewController()?.view.window
					if let style = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: ODPrefs.interfaceStyle)) {
						window?.overrideUserInterfaceStyle = style
					}
					window?.tintColor = UIColor(Color(hex: UserDefaults.standard.string(forKey: ODPrefs.tintColor) ?? ODTheme.moonlightHex))
				}
				.onChange(of: _scenePhase) { phase in
					guard phase == .active else { return }
					Task { @MainActor in
						await ODCertificateStatusStore.shared.checkAllIfNeeded()
						await ODCatalogStore.shared.refreshIfNeeded()
					}
				}
		}
	}
	
	private func _handleURL(_ url: URL) {
		if url.scheme == "odysseus" {
			/// odysseus://select-certificate?cert=<nickname|uuid|profile-name|profile-uuid|team-name|index>
			/// odysseus://switch-certificate?cert=<nickname|uuid|profile-name|profile-uuid|team-name|index>
			if url.host == "select-certificate" || url.host == "switch-certificate" {
				_handleCertificateSelectionURL(url)
				return
			}
			/// odysseus://import-certificate?p12=<base64>&mobileprovision=<base64>&password=<base64>
			if url.host == "import-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
					let queryItems = components.queryItems
				else {
					return
				}
				
				func queryValue(_ name: String) -> String? {
					queryItems.first(where: { $0.name == name })?.value?.removingPercentEncoding
				}
				
				guard
					let p12Base64 = queryValue("p12"),
					let provisionBase64 = queryValue("mobileprovision"),
					let passwordBase64 = queryValue("password"),
					let passwordData = Data(base64Encoded: passwordBase64),
					let password = String(data: passwordData, encoding: .utf8)
				else {
					return
				}
				
				let generator = UINotificationFeedbackGenerator()
				generator.prepare()
				
				guard
					let p12URL = FileManager.default.decodeAndWrite(base64: p12Base64, pathComponent: ".p12"),
					let provisionURL = FileManager.default.decodeAndWrite(base64: provisionBase64, pathComponent: ".mobileprovision"),
					FR.checkPasswordForCertificate(for: p12URL, with: password, using: provisionURL)
				else {
					generator.notificationOccurred(.error)
					return
				}
				
				FR.handleCertificateFiles(
					p12URL: p12URL,
					provisionURL: provisionURL,
					p12Password: password
				) { error in
					if let error = error {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
					} else {
						generator.notificationOccurred(.success)
					}
				}
				
				return
			}
			/// odysseus://export-certificate?callback_template=<template>
			/// ?callback_template=: This is how we callback to the application requesting the certificate, this will be a url scheme
			/// 	example: livecontainer%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29
			/// 	decoded: livecontainer://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)
			/// $(BASE64_CERT) and $(PASSWORD) must be presenting in the callback template so we can replace them with the proper content
			if url.host == "export-certificate" {
				guard
					let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
				else {
					return
				}
				
				let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
				guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
				
				FR.exportCertificateAndOpenUrl(using: callbackTemplate)
			}
			/// odysseus://source/<url>
			if let fullPath = url.validatedScheme(after: "/source/") {
				FR.handleSource(fullPath) { }
			}
			/// odysseus://install/<url.ipa>
			if
				let fullPath = url.validatedScheme(after: "/install/"),
				let downloadURL = URL(string: fullPath)
			{
				_ = DownloadManager.shared.startDownload(from: downloadURL)
			}
		} else {
			if url.pathExtension == "ipa" || url.pathExtension == "tipa" {
				if FileManager.default.isFileFromFileProvider(at: url) {
					guard url.startAccessingSecurityScopedResource() else { return }
					FR.handlePackageFile(url) { _ in }
				} else {
					FR.handlePackageFile(url) { _ in }
				}
				
				return
			}
		}
	}

	private func _handleCertificateSelectionURL(_ url: URL) {
		guard
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else {
			return
		}
		let queryItems = components.queryItems ?? []

		func queryValue(_ names: String...) -> String? {
			for name in names {
				if let value = queryItems.first(where: { $0.name.lowercased() == name })?.value?.removingPercentEncoding {
					return value
				}
			}
			return nil
		}

		let pathSelector = components.path
			.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			.removingPercentEncoding

		guard
			let selector = queryValue("cert", "certificate", "name", "nickname", "uuid", "id", "index")
				?? (pathSelector?.isEmpty == false ? pathSelector : nil)
		else {
			return
		}

		let generator = UINotificationFeedbackGenerator()
		generator.prepare()

		guard let index = Storage.shared.selectedCertificateIndex(matching: selector) else {
			generator.notificationOccurred(.error)
			UIAlertController.showAlertWithOk(
				title: .localized("Certificate Not Found"),
				message: .localized("No certificate matches \"%@\".", arguments: selector)
			)
			return
		}

		UserDefaults.standard.set(index, forKey: "feather.selectedCert")
		generator.notificationOccurred(.success)
	}
}

class AppDelegate: NSObject, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		ODPrefs.registerDefaults()
		_createPipeline()
		_createDocumentsDirectories()
		ResetView.clearWorkCache()
		Task { @MainActor in
			await _installStartupSources()
		}
		return true
	}
	
	@MainActor
	private func _installStartupSources() async {
		var insertedCount = DefaultSourceInstaller.installIfNeeded()
		
		do {
			insertedCount += try await DefaultSourceInstaller.updateFromRemote()
		} catch {
			Logger.misc.error("Failed to update startup sources: \(error.localizedDescription)")
		}
		
		if insertedCount > 0 {
			SourceFetchErrorToastCenter.shared.show(
				.localized("Added %d sources", arguments: insertedCount),
				systemImage: "checkmark.circle.fill"
			)
		}
		
		await ODCatalogStore.shared.load()
		ODExpiryReminderScheduler.reschedule()
		await ODCertificateStatusStore.shared.checkAllIfNeeded()
	}

	private func _createPipeline() {
		DataLoader.sharedUrlCache.diskCapacity = 0
		
		let pipeline = ImagePipeline {
			let dataLoader: DataLoader = {
				let config = URLSessionConfiguration.default
				config.urlCache = nil
				return DataLoader(configuration: config)
			}()
			let dataCache = try? DataCache(name: "com.mirazbakis.Odysseus.datacache") // disk cache
			let imageCache = Nuke.ImageCache() // memory cache
			dataCache?.sizeLimit = 500 * 1024 * 1024
			imageCache.costLimit = 100 * 1024 * 1024
			$0.dataCache = dataCache
			$0.imageCache = imageCache
			$0.dataLoader = dataLoader
			$0.dataCachePolicy = .automatic
			$0.isStoringPreviewsInMemoryCache = false
		}
		
		ImagePipeline.shared = pipeline
	}
	
	private func _createDocumentsDirectories() {
		let fileManager = FileManager.default

		let directories: [URL] = [
			fileManager.archives,
			fileManager.certificates,
			fileManager.signed,
			fileManager.unsigned
		]
		
		for url in directories {
			try? fileManager.createDirectoryIfNeeded(at: url)
		}
	}
	
}
