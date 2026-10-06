//
//  ZsignHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignSwift
import UIKit

/// Signing files that don't come from a stored CertificatePair.
struct ODSigningOverride {
	let p12Path: String
	let p12Password: String
	let provisionPath: String
}

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	private var _override: ODSigningOverride?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil,
		identityOverride: ODSigningOverride? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
		self._override = identityOverride
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		if let identity = _override {
			let _ = Zsign.sign(
				appPath: _appUrl.relativePath,
				provisionPath: identity.provisionPath,
				p12Path: identity.p12Path,
				p12Password: identity.p12Password,
				entitlementsPath: _options.appEntitlementsFile?.path ?? "",
				removeProvision: !_options.removeProvisioning,
				completion: { _, error in
					self.hadError = error
				}
			)
			return
		}
		
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		let _ = Zsign.sign(
			appPath: _appUrl.relativePath,
			provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
			p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
			p12Password: cert.password ?? "",
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)
	}
	
	func adhocSign() async throws {
		let _ = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: !_options.removeProvisioning,
			completion: { _, error in
				self.hadError = error
			}
		)
	}
}
