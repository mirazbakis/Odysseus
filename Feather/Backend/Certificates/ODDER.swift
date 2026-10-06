//
//  ODDER.swift
//  Odysseus
//
//  A very small DER reader/writer. Just enough ASN.1 to read X.509
//  certificates and to build and read OCSP messages (RFC 6960).
//

import Foundation

struct ODDERNode {
	let tag: UInt8
	/// Contents only (no tag/length).
	let value: Data
	/// The full TLV encoding.
	let raw: Data

	var isConstructed: Bool { tag & 0x20 != 0 }
	var tagClass: UInt8 { tag & 0xC0 }
	var tagNumber: UInt8 { tag & 0x1F }

	/// Children when the node is constructed.
	var children: [ODDERNode] {
		(try? ODDER.parseAll(value)) ?? []
	}

	/// Context-specific tag number (e.g. [0], [1]) or nil.
	var contextNumber: UInt8? {
		tagClass == 0x80 ? tagNumber : nil
	}
}

enum ODDERError: Error {
	case truncated
	case unsupportedLength
	case unexpected(String)
}

enum ODDER {
	// MARK: Read
	static func parse(_ data: Data, at offset: Int = 0) throws -> (node: ODDERNode, next: Int) {
		let bytes = [UInt8](data)
		guard offset + 2 <= bytes.count else { throw ODDERError.truncated }

		let tag = bytes[offset]
		var index = offset + 1
		var length = Int(bytes[index])
		index += 1

		if length & 0x80 != 0 {
			let count = length & 0x7F
			guard count > 0, count <= 4, index + count <= bytes.count else {
				throw ODDERError.unsupportedLength
			}
			length = 0
			for _ in 0..<count {
				length = (length << 8) | Int(bytes[index])
				index += 1
			}
		}

		guard index + length <= bytes.count else { throw ODDERError.truncated }

		let start = data.startIndex
		let value = data.subdata(in: (start + index)..<(start + index + length))
		let raw = data.subdata(in: (start + offset)..<(start + index + length))
		return (ODDERNode(tag: tag, value: value, raw: raw), index + length)
	}

	static func parseAll(_ data: Data) throws -> [ODDERNode] {
		var nodes: [ODDERNode] = []
		var offset = 0
		while offset < data.count {
			let (node, next) = try parse(data, at: offset)
			nodes.append(node)
			offset = next
		}
		return nodes
	}

	static func root(_ data: Data) throws -> ODDERNode {
		try parse(data).node
	}

	// MARK: Write
	static func length(_ count: Int) -> Data {
		if count < 0x80 { return Data([UInt8(count)]) }
		var bytes: [UInt8] = []
		var value = count
		while value > 0 {
			bytes.insert(UInt8(value & 0xFF), at: 0)
			value >>= 8
		}
		return Data([0x80 | UInt8(bytes.count)] + bytes)
	}

	static func tlv(_ tag: UInt8, _ content: Data) -> Data {
		var out = Data([tag])
		out.append(length(content.count))
		out.append(content)
		return out
	}

	static func sequence(_ parts: Data...) -> Data {
		tlv(0x30, parts.reduce(Data(), +))
	}

	static func octetString(_ content: Data) -> Data { tlv(0x04, content) }
	static let null = Data([0x05, 0x00])

	static func oid(_ dotted: String) -> Data {
		let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
		guard parts.count >= 2 else { return Data() }
		var body = Data([UInt8(parts[0] * 40 + parts[1])])
		for part in parts.dropFirst(2) {
			var stack: [UInt8] = [UInt8(part & 0x7F)]
			var value = part >> 7
			while value > 0 {
				stack.insert(UInt8(value & 0x7F) | 0x80, at: 0)
				value >>= 7
			}
			body.append(contentsOf: stack)
		}
		return tlv(0x06, body)
	}

	static func oidString(_ node: ODDERNode) -> String? {
		guard node.tag == 0x06, !node.value.isEmpty else { return nil }
		let bytes = [UInt8](node.value)
		var parts: [UInt64] = [UInt64(bytes[0] / 40), UInt64(bytes[0] % 40)]
		var value: UInt64 = 0
		for byte in bytes.dropFirst() {
			value = (value << 7) | UInt64(byte & 0x7F)
			if byte & 0x80 == 0 {
				parts.append(value)
				value = 0
			}
		}
		return parts.map(String.init).joined(separator: ".")
	}

	// MARK: Time
	/// Parses UTCTime (0x17) and GeneralizedTime (0x18).
	static func date(_ node: ODDERNode) -> Date? {
		guard let string = String(data: node.value, encoding: .ascii) else { return nil }
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")

		var trimmed = string.replacingOccurrences(of: "Z", with: "")
		if let dot = trimmed.firstIndex(of: ".") {
			trimmed = String(trimmed[..<dot])
		}

		switch node.tag {
		case 0x17:
			formatter.dateFormat = trimmed.count == 12 ? "yyMMddHHmmss" : "yyMMddHHmm"
		case 0x18:
			formatter.dateFormat = trimmed.count == 14 ? "yyyyMMddHHmmss" : "yyyyMMddHHmm"
		default:
			return nil
		}
		return formatter.date(from: trimmed)
	}

	/// Integer bytes with any leading zero padding removed.
	static func normalizedInteger(_ data: Data) -> Data {
		var bytes = [UInt8](data)
		while bytes.count > 1 && bytes[0] == 0 {
			bytes.removeFirst()
		}
		return Data(bytes)
	}
}

extension Data {
	var odHex: String { map { String(format: "%02X", $0) }.joined() }
}
