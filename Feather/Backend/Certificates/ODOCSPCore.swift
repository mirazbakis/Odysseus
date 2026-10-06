//
//  ODOCSPCore.swift
//  Odysseus
//
//  Builds OCSP requests and reads OCSP responses (RFC 6960).
//  Pure DER code, no networking, so it can be tested anywhere.
//

import Foundation

enum ODOCSPCertStatus: Equatable {
	case good
	case revoked(date: Date?, reason: Int?)
	case unknown
}

struct ODOCSPParsedResponse {
	/// 0 = successful. Anything else is an OCSP error status.
	let responseStatus: Int
	let certStatus: ODOCSPCertStatus?
	let producedAt: Date?
	let thisUpdate: Date?
	let nextUpdate: Date?
	/// DER of tbsResponseData, for signature checks.
	let tbsResponseData: Data?
	let signatureAlgorithmOID: String?
	let signature: Data?
	/// Certificates the responder sent along.
	let certificates: [Data]
}

enum ODOCSPCore {
	static let sha1OID = "1.3.14.3.2.26"
	static let basicResponseOID = "1.3.6.1.5.5.7.48.1.1"

	/// CertID ::= SEQUENCE { hashAlgorithm, issuerNameHash, issuerKeyHash, serialNumber }
	static func certID(issuerNameHash: Data, issuerKeyHash: Data, serial: Data) -> Data {
		var serialBytes = [UInt8](serial)
		if let first = serialBytes.first, first & 0x80 != 0 {
			serialBytes.insert(0, at: 0) // keep it positive
		}
		return ODDER.sequence(
			ODDER.sequence(ODDER.oid(sha1OID), ODDER.null),
			ODDER.octetString(issuerNameHash),
			ODDER.octetString(issuerKeyHash),
			ODDER.tlv(0x02, Data(serialBytes))
		)
	}

	/// OCSPRequest ::= SEQUENCE { tbsRequest SEQUENCE { requestList SEQUENCE OF Request } }
	static func request(certID: Data) -> Data {
		let req = ODDER.sequence(certID)
		let requestList = ODDER.sequence(req)
		let tbsRequest = ODDER.sequence(requestList)
		return ODDER.sequence(tbsRequest)
	}

	static func parse(response data: Data, serial: Data) throws -> ODOCSPParsedResponse {
		let root = try ODDER.root(data)
		let top = root.children
		guard let statusNode = top.first, statusNode.tag == 0x0A else {
			throw ODDERError.unexpected("responseStatus")
		}
		let status = Int(statusNode.value.first ?? 0xFF)
		guard status == 0 else {
			return ODOCSPParsedResponse(responseStatus: status, certStatus: nil, producedAt: nil, thisUpdate: nil, nextUpdate: nil, tbsResponseData: nil, signatureAlgorithmOID: nil, signature: nil, certificates: [])
		}

		// responseBytes [0] EXPLICIT SEQUENCE { responseType OID, response OCTET STRING }
		guard
			let bytesWrapper = top.first(where: { $0.tag == 0xA0 }),
			let responseBytes = bytesWrapper.children.first,
			responseBytes.children.count == 2,
			ODDER.oidString(responseBytes.children[0]) == basicResponseOID,
			responseBytes.children[1].tag == 0x04
		else {
			throw ODDERError.unexpected("responseBytes")
		}

		// BasicOCSPResponse ::= SEQUENCE { tbsResponseData, signatureAlgorithm, signature, certs [0] OPTIONAL }
		let basic = try ODDER.root(responseBytes.children[1].value)
		let basicParts = basic.children
		guard basicParts.count >= 3 else { throw ODDERError.unexpected("basic") }

		let tbs = basicParts[0]
		let sigAlg = basicParts[1].children.first.flatMap(ODDER.oidString)
		let signature = basicParts[2].tag == 0x03 ? Data(basicParts[2].value.dropFirst()) : nil
		var certs: [Data] = []
		if let certsWrapper = basicParts.first(where: { $0.tag == 0xA0 }), let list = certsWrapper.children.first {
			certs = list.children.map(\.raw)
		}

		// ResponseData ::= SEQUENCE { version [0] OPTIONAL, responderID, producedAt, responses, extensions [1] OPTIONAL }
		var tbsParts = tbs.children
		if tbsParts.first?.tag == 0xA0 { tbsParts.removeFirst() }
		guard tbsParts.count >= 3 else { throw ODDERError.unexpected("tbs") }

		let producedAt = ODDER.date(tbsParts[1])
		let responses = tbsParts[2].children

		let wantedSerial = ODDER.normalizedInteger(serial)
		var certStatus: ODOCSPCertStatus?
		var thisUpdate: Date?
		var nextUpdate: Date?

		for single in responses {
			let parts = single.children
			guard parts.count >= 3 else { continue }
			let idParts = parts[0].children
			guard idParts.count == 4, ODDER.normalizedInteger(idParts[3].value) == wantedSerial else { continue }

			let statusNode = parts[1]
			switch statusNode.tag {
			case 0x80:
				certStatus = .good
			case 0xA1:
				let info = statusNode.children
				let date = info.first.flatMap(ODDER.date)
				var reason: Int?
				if let reasonWrapper = info.first(where: { $0.tag == 0xA0 }),
				   let enumNode = reasonWrapper.children.first,
				   enumNode.tag == 0x0A,
				   let value = enumNode.value.first {
					reason = Int(value)
				}
				certStatus = .revoked(date: date, reason: reason)
			default:
				certStatus = .unknown
			}

			thisUpdate = ODDER.date(parts[2])
			if let nextWrapper = parts.dropFirst(3).first(where: { $0.tag == 0xA0 }) {
				nextUpdate = nextWrapper.children.first.flatMap(ODDER.date)
			}
			break
		}

		return ODOCSPParsedResponse(
			responseStatus: 0,
			certStatus: certStatus,
			producedAt: producedAt,
			thisUpdate: thisUpdate,
			nextUpdate: nextUpdate,
			tbsResponseData: tbs.raw,
			signatureAlgorithmOID: sigAlg,
			signature: signature,
			certificates: certs
		)
	}

	/// RFC 5280 CRLReason names.
	static func reasonName(_ reason: Int?) -> String? {
		guard let reason else { return nil }
		switch reason {
		case 0: return "Unspecified"
		case 1: return "Key compromise"
		case 2: return "CA compromise"
		case 3: return "Affiliation changed"
		case 4: return "Superseded"
		case 5: return "Cessation of operation"
		case 6: return "Certificate hold"
		case 8: return "Remove from CRL"
		case 9: return "Privilege withdrawn"
		case 10: return "AA compromise"
		default: return "Reason \(reason)"
		}
	}

	static func responseStatusName(_ status: Int) -> String {
		switch status {
		case 1: return "Malformed request"
		case 2: return "Internal error"
		case 3: return "Try later"
		case 5: return "Signature required"
		case 6: return "Unauthorized"
		default: return "Error \(status)"
		}
	}
}
