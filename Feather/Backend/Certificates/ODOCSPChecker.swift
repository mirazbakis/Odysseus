//
//  ODOCSPChecker.swift
//  Odysseus
//
//  Real OCSP revocation checks against Apple's responder.
//
//  1. Read the signing certificate (leaf) from the .p12 (or the
//     provisioning profile as a fallback).
//  2. Find its issuer: the bundled Apple WWDR intermediates, or the
//     caIssuers URL in the certificate.
//  3. POST an OCSP request (SHA-1 CertID) to the responder named in the
//     certificate (ocsp.apple.com).
//  4. Read the answer: good / revoked (date + reason) / unknown, and
//     check the responder's signature with the Security framework.
//
//  Unlike the old one-way `revoked` flag, every check can move a
//  certificate in either direction.
//

import Foundation
import Security
import CryptoKit
import OSLog

// MARK: - Result
struct ODOCSPResult: Codable, Equatable {
	enum Status: String, Codable {
		case valid
		case revoked
		case unknown
		case couldntCheck
	}

	var status: Status
	var revokedAt: Date?
	var reason: Int?
	var checkedAt: Date
	var producedAt: Date?
	var nextUpdate: Date?
	/// The responder's signature was checked and chains to Apple.
	var signatureVerified: Bool
	var responderURL: String?
	var detail: String?

	var reasonName: String? { ODOCSPCore.reasonName(reason) }

	var title: String {
		switch status {
		case .valid: return .localized("Valid")
		case .revoked: return .localized("Revoked")
		case .unknown: return .localized("Unknown")
		case .couldntCheck: return .localized("Couldn't check")
		}
	}

	var icon: String {
		switch status {
		case .valid: return "checkmark.seal.fill"
		case .revoked: return "xmark.octagon.fill"
		case .unknown: return "questionmark.circle.fill"
		case .couldntCheck: return "exclamationmark.triangle.fill"
		}
	}

	static func couldntCheck(_ detail: String, url: String? = nil) -> ODOCSPResult {
		ODOCSPResult(status: .couldntCheck, revokedAt: nil, reason: nil, checkedAt: Date(), producedAt: nil, nextUpdate: nil, signatureVerified: false, responderURL: url, detail: detail)
	}
}

// MARK: - Checker
enum ODOCSPChecker {
	private static let _issuerCache = NSCache<NSData, NSData>()

	static func check(certificateDER: Data) async -> ODOCSPResult {
		let leaf: ODX509
		do {
			leaf = try ODX509(der: certificateDER)
		} catch {
			return .couldntCheck(.localized("The certificate could not be read."))
		}

		let issuer = await _issuer(for: leaf)

		guard let issuerKeyHash = issuer?.keyHash ?? leaf.authorityKeyID else {
			return .couldntCheck(.localized("The issuing Apple certificate wasn't found."))
		}

		let certID = ODOCSPCore.certID(
			issuerNameHash: leaf.issuerNameHash,
			issuerKeyHash: issuerKeyHash,
			serial: leaf.serial
		)
		let requestBody = ODOCSPCore.request(certID: certID)

		var lastError = String.localized("No OCSP responder is listed in the certificate.")
		for url in _responderURLs(for: leaf, issuer: issuer) {
			do {
				var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
				request.httpMethod = "POST"
				request.setValue("application/ocsp-request", forHTTPHeaderField: "Content-Type")
				request.setValue("application/ocsp-response", forHTTPHeaderField: "Accept")
				request.httpBody = requestBody

				let (data, response) = try await URLSession.shared.data(for: request)
				guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
					lastError = .localized("The OCSP responder returned an error.")
					continue
				}

				let parsed = try ODOCSPCore.parse(response: data, serial: leaf.serial)
				guard parsed.responseStatus == 0 else {
					lastError = ODOCSPCore.responseStatusName(parsed.responseStatus)
					continue
				}

				let verification = _verifySignature(parsed, issuer: issuer)
				if verification == .invalid {
					lastError = .localized("The OCSP response signature is not valid.")
					continue
				}

				var result = ODOCSPResult(
					status: .unknown,
					revokedAt: nil,
					reason: nil,
					checkedAt: Date(),
					producedAt: parsed.producedAt,
					nextUpdate: parsed.nextUpdate,
					signatureVerified: verification == .verified,
					responderURL: url.absoluteString,
					detail: nil
				)

				switch parsed.certStatus {
				case .good:
					result.status = .valid
				case .revoked(let date, let reason):
					result.status = .revoked
					result.revokedAt = date
					result.reason = reason
				case .unknown:
					result.status = .unknown
					result.detail = .localized("Apple's responder doesn't know this certificate.")
				case .none:
					result.status = .unknown
					result.detail = .localized("The certificate wasn't in Apple's answer.")
				}

				if verification == .unverifiable {
					result.detail = [result.detail, String.localized("The responder's signature could not be verified.")]
						.compactMap { $0 }
						.joined(separator: " ")
				}

				return result
			} catch {
				lastError = error.localizedDescription
			}
		}

		return .couldntCheck(lastError)
	}

	// MARK: Responder
	private static func _responderURLs(for leaf: ODX509, issuer: ODX509?) -> [URL] {
		var urls = leaf.ocspURLs
		if urls.isEmpty {
			// Same fallbacks zsign uses.
			let issuerName = issuer?.commonName ?? ""
			let ou = issuer.flatMap { _organizationalUnit(of: $0) } ?? ""
			let path: String
			if issuerName.contains("G6") || ou == "G6" { path = "ocsp03-wwdrg6" }
			else if issuerName.contains("G3") || ou == "G3" { path = "ocsp03-wwdrg3" }
			else if issuerName.contains("G2") || ou == "G2" { path = "ocsp03-wwdrg2" }
			else if ou == "G4" { path = "ocsp03-wwdrg4" }
			else if ou == "G5" { path = "ocsp03-wwdrg5" }
			else { path = "ocsp03-wwdr01" }
			if let url = URL(string: "http://ocsp.apple.com/\(path)") {
				urls.append(url)
			}
		}
		return urls
	}

	private static func _organizationalUnit(of cert: ODX509) -> String? {
		guard let secCert = SecCertificateCreateWithData(nil, cert.der as CFData),
			  let summary = SecCertificateCopySubjectSummary(secCert) as String? else {
			return nil
		}
		for gen in ["G2", "G3", "G4", "G5", "G6", "G7", "G8"] where summary.contains(gen) {
			return gen
		}
		return nil
	}

	// MARK: Issuer
	static var bundledIntermediates: [ODX509] = {
		let names = ["AppleWWDRCA", "AppleWWDRCAG2", "AppleWWDRCAG3", "AppleWWDRCAG4", "AppleWWDRCAG5", "AppleWWDRCAG6"]
		return names.compactMap { name in
			let url = Bundle.main.url(forResource: name, withExtension: "cer")
				?? Bundle.main.url(forResource: name, withExtension: "cer", subdirectory: "WWDR")
			guard let url, let data = try? Data(contentsOf: url) else { return nil }
			return try? ODX509(der: data)
		}
	}()

	private static func _issuer(for leaf: ODX509) async -> ODX509? {
		let candidates = bundledIntermediates.filter { $0.subjectNameDER == leaf.issuerNameDER }
		if let aki = leaf.authorityKeyID, let match = candidates.first(where: { $0.subjectKeyID == aki || $0.keyHash == aki }) {
			return match
		}
		if candidates.count == 1 {
			return candidates.first
		}

		for url in leaf.caIssuerURLs {
			if let cached = _issuerCache.object(forKey: url.absoluteString.data(using: .utf8)! as NSData) {
				return try? ODX509(der: cached as Data)
			}
			guard let (data, _) = try? await URLSession.shared.data(from: url),
				  let cert = try? ODX509(der: data),
				  cert.subjectNameDER == leaf.issuerNameDER
			else { continue }
			_issuerCache.setObject(data as NSData, forKey: url.absoluteString.data(using: .utf8)! as NSData)
			return cert
		}

		return candidates.first
	}

	// MARK: Signature
	private enum Verification {
		case verified
		case unverifiable
		case invalid
	}

	private static func _verifySignature(_ response: ODOCSPParsedResponse, issuer: ODX509?) -> Verification {
		guard
			let tbs = response.tbsResponseData,
			let signature = response.signature,
			let algorithmOID = response.signatureAlgorithmOID,
			let algorithm = _secAlgorithm(algorithmOID)
		else {
			return .unverifiable
		}

		var chain: [SecCertificate] = response.certificates.compactMap {
			SecCertificateCreateWithData(nil, $0 as CFData)
		}
		if let issuer, let issuerCert = SecCertificateCreateWithData(nil, issuer.der as CFData) {
			chain.append(issuerCert)
		}
		guard let signer = chain.first, let key = SecCertificateCopyKey(signer) else {
			return .unverifiable
		}

		var error: Unmanaged<CFError>?
		guard SecKeyVerifySignature(key, algorithm, tbs as CFData, signature as CFData, &error) else {
			return .invalid
		}

		// The signer must chain to a trusted Apple root.
		var trust: SecTrust?
		let policy = SecPolicyCreateBasicX509()
		guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess, let trust else {
			return .unverifiable
		}
		var trustError: CFError?
		let trusted = SecTrustEvaluateWithError(trust, &trustError)
		guard trusted else {
			return .unverifiable
		}

		// Make sure the chain actually ends at Apple.
		let count = SecTrustGetCertificateCount(trust)
		if count > 0, let root = _certificate(at: count - 1, in: trust) {
			let summary = (SecCertificateCopySubjectSummary(root) as String?) ?? ""
			if !summary.localizedCaseInsensitiveContains("Apple") {
				return .unverifiable
			}
		}

		return .verified
	}

	private static func _certificate(at index: Int, in trust: SecTrust) -> SecCertificate? {
		guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], index < chain.count else {
			return nil
		}
		return chain[index]
	}

	private static func _secAlgorithm(_ oid: String) -> SecKeyAlgorithm? {
		switch oid {
		case "1.2.840.113549.1.1.5": return .rsaSignatureMessagePKCS1v15SHA1
		case "1.2.840.113549.1.1.11": return .rsaSignatureMessagePKCS1v15SHA256
		case "1.2.840.113549.1.1.12": return .rsaSignatureMessagePKCS1v15SHA384
		case "1.2.840.113549.1.1.13": return .rsaSignatureMessagePKCS1v15SHA512
		case "1.2.840.10045.4.3.2": return .ecdsaSignatureMessageX962SHA256
		case "1.2.840.10045.4.3.3": return .ecdsaSignatureMessageX962SHA384
		case "1.2.840.10045.4.3.4": return .ecdsaSignatureMessageX962SHA512
		default: return nil
		}
	}
}
