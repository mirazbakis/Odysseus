//
//  ODX509.swift
//  Odysseus
//
//  Reads the parts of an X.509 certificate that OCSP needs.
//

import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

struct ODX509 {
	let der: Data
	let serial: Data
	let issuerNameDER: Data
	let subjectNameDER: Data
	/// Raw subjectPublicKey bits (without the unused-bits byte).
	let publicKeyBits: Data
	let notBefore: Date?
	let notAfter: Date?
	let ocspURLs: [URL]
	let caIssuerURLs: [URL]
	let authorityKeyID: Data?
	let subjectKeyID: Data?

	#if canImport(Security)
	var commonName: String? {
		guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
		var name: CFString?
		SecCertificateCopyCommonName(cert, &name)
		return name as String?
	}

	#endif

	#if canImport(CryptoKit)
	/// SHA-1 of this certificate's public key, i.e. the OCSP issuerKeyHash
	/// when this certificate is the issuer.
	var keyHash: Data {
		Data(Insecure.SHA1.hash(data: publicKeyBits))
	}

	/// SHA-1 of this certificate's subject name, i.e. the OCSP
	/// issuerNameHash when this certificate is the issuer.
	var subjectNameHash: Data {
		Data(Insecure.SHA1.hash(data: subjectNameDER))
	}

	var issuerNameHash: Data {
		Data(Insecure.SHA1.hash(data: issuerNameDER))
	}
	#endif

	init(der: Data) throws {
		self.der = der
		let cert = try ODDER.root(der)
		guard let tbs = cert.children.first else { throw ODDERError.unexpected("tbs") }
		var fields = tbs.children
		if fields.first?.tag == 0xA0 { fields.removeFirst() } // version
		guard fields.count >= 6 else { throw ODDERError.unexpected("fields") }

		serial = ODDER.normalizedInteger(fields[0].value)
		issuerNameDER = fields[2].raw
		let validity = fields[3].children
		notBefore = validity.first.flatMap(ODDER.date)
		notAfter = validity.count > 1 ? ODDER.date(validity[1]) : nil
		subjectNameDER = fields[4].raw

		let spki = fields[5].children
		if spki.count > 1, spki[1].tag == 0x03, spki[1].value.count > 1 {
			publicKeyBits = spki[1].value.dropFirst()
		} else {
			publicKeyBits = Data()
		}

		var ocsp: [URL] = []
		var caIssuers: [URL] = []
		var aki: Data?
		var ski: Data?

		if let extWrapper = fields.first(where: { $0.tag == 0xA3 }), let extList = extWrapper.children.first {
			for ext in extList.children {
				let parts = ext.children
				guard let oid = parts.first.flatMap(ODDER.oidString), let valueNode = parts.last, valueNode.tag == 0x04 else {
					continue
				}
				guard let inner = try? ODDER.root(valueNode.value) else { continue }

				switch oid {
				case "1.3.6.1.5.5.7.1.1": // authorityInfoAccess
					for access in inner.children {
						let accessParts = access.children
						guard
							accessParts.count == 2,
							let method = ODDER.oidString(accessParts[0]),
							accessParts[1].tag == 0x86,
							let string = String(data: accessParts[1].value, encoding: .ascii),
							let url = URL(string: string)
						else { continue }
						if method == "1.3.6.1.5.5.7.48.1" { ocsp.append(url) }
						if method == "1.3.6.1.5.5.7.48.2" { caIssuers.append(url) }
					}
				case "2.5.29.35": // authorityKeyIdentifier
					aki = inner.children.first(where: { $0.tag == 0x80 })?.value
				case "2.5.29.14": // subjectKeyIdentifier
					ski = inner.tag == 0x04 ? inner.value : nil
				default:
					break
				}
			}
		}

		ocspURLs = ocsp
		caIssuerURLs = caIssuers
		authorityKeyID = aki
		subjectKeyID = ski
	}
}

// MARK: - Loading the signing certificate
#if canImport(Security)
enum ODCertificateLoader {
	/// The leaf certificate inside a .p12, using the password.
	static func leafCertificate(p12 url: URL, password: String?) -> Data? {
		guard let data = try? Data(contentsOf: url) else { return nil }
		let options = [kSecImportExportPassphrase as String: password ?? ""] as CFDictionary
		var items: CFArray?
		guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
			  let array = items as? [[String: Any]],
			  let first = array.first,
			  let identityRef = first[kSecImportItemIdentity as String]
		else {
			return nil
		}
		// swiftlint:disable:next force_cast
		let identity = identityRef as! SecIdentity
		var cert: SecCertificate?
		guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return nil }
		return SecCertificateCopyData(cert) as Data
	}

	/// The first DeveloperCertificates entry of a .mobileprovision.
	static func provisionCertificates(_ url: URL) -> [Data] {
		guard let data = try? Data(contentsOf: url),
			  let start = data.range(of: Data("<?xml".utf8)),
			  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
		else { return [] }
		let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
		guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
			return []
		}
		return plist["DeveloperCertificates"] as? [Data] ?? []
	}

	static func certificateDER(for cert: CertificatePair) -> Data? {
		if let p12 = Storage.shared.getFile(.certificate, from: cert),
		   let der = leafCertificate(p12: p12, password: cert.password) {
			return der
		}
		if let provision = Storage.shared.getFile(.provision, from: cert) {
			return provisionCertificates(provision).first
		}
		return nil
	}
}
#endif
