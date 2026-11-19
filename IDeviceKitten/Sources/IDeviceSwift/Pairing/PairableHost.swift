//
//  PairableHost.swift
//  IDeviceKit (Odysseus)
//
//  Pairs this device with itself. On iOS 27, Settings › Privacy & Security ›
//  Developer Mode lists pairable hosts on the network; this listens on a TCP
//  port, hands idevice's pairable host the connection, and returns the
//  RemotePairing file plus the device's identity (name, model, UDID).
//  Built on idevice's `pairable_host_*` API.
//

import Foundation
import Darwin
import IDevice

public final class PairableHost: @unchecked Sendable {
	public struct Advertisement: Sendable {
		/// Bonjour instance name for `_remotepairing-pairable-host._tcp`.
		public let serviceID: String
		public let port: Int32
		public let txtRecord: [String: Data]
	}

	public struct Result: Sendable {
		public let udid: String
		public let deviceName: String
		public let model: String
		/// The RemotePairing (RPPairing) file, written to the path given to `run`.
		public let pairingFileURL: URL
	}

	public enum Failure: LocalizedError {
		case socket(String)
		case cancelled
		case idevice(String)

		public var errorDescription: String? {
			switch self {
			case .socket(let message): return "Couldn't listen for the pairing request: \(message)"
			case .cancelled: return "Pairing was cancelled."
			case .idevice(let message): return message.isEmpty ? "Pairing failed." : "Pairing failed: \(message)"
			}
		}
	}

	public static let serviceType = "_remotepairing-pairable-host._tcp."

	private let _name: String
	private let _lock = NSLock()
	private var _listenFD: Int32 = -1
	private var _cancelled = false

	/// - Parameter name: shown on the device as "Pair with <name>".
	public init(name: String) {
		_name = name
	}

	/// Stops waiting for a device. Safe to call from any thread.
	public func cancel() {
		_lock.lock()
		_cancelled = true
		let fd = _listenFD
		_listenFD = -1
		_lock.unlock()
		if fd >= 0 {
			shutdown(fd, SHUT_RDWR)
			close(fd)
		}
	}

	/// Blocks until a device pairs, pairing fails, or `cancel()` is called.
	/// - Parameters:
	///   - pairingFileURL: where to write the RemotePairing file.
	///   - onReady: publish the Bonjour service with these details.
	///   - onPin: show this 6-digit code; the user types it on the device.
	public func run(
		pairingFileURL: URL,
		onReady: @escaping (Advertisement) -> Void,
		onPin: @escaping (String) -> Void
	) throws -> Result {
		// 1. Listening socket on any free port.
		let listenFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
		guard listenFD >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
		var yes: Int32 = 1
		setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

		var addr = sockaddr_in()
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = 0
		addr.sin_addr.s_addr = INADDR_ANY
		let bound = withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard bound == 0, listen(listenFD, 4) == 0 else {
			let message = String(cString: strerror(errno))
			close(listenFD)
			throw Failure.socket(message)
		}
		var boundAddr = sockaddr_in()
		var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
		_ = withUnsafeMutablePointer(to: &boundAddr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(listenFD, $0, &boundLen)
			}
		}
		let port = Int32(UInt16(bigEndian: boundAddr.sin_port))

		_lock.lock()
		if _cancelled {
			_lock.unlock()
			close(listenFD)
			throw Failure.cancelled
		}
		_listenFD = listenFD
		_lock.unlock()
		defer { cancelListening() }

		// 2. Host identity and the TXT record to advertise.
		var handle: OpaquePointer?
		var serviceID: UnsafeMutablePointer<CChar>?
		var txtData: UnsafeMutablePointer<UInt8>?
		var txtLen: UInt = 0
		if let err = pairable_host_prepare(_name, nil, false, &handle, &serviceID, &txtData, &txtLen, nil) {
			throw Self._failure(err)
		}
		defer { pairable_host_free(handle) }

		let service = serviceID.map { String(cString: $0) } ?? _name
		if let serviceID { idevice_string_free(serviceID) }
		var txt: [String: Data] = [:]
		if let txtData {
			let bytes = Data(bytes: txtData, count: Int(txtLen))
			idevice_data_free(txtData, txtLen)
			if let dict = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] {
				for (key, value) in dict {
					switch value {
					case let data as Data: txt[key] = data
					case let string as String: txt[key] = Data(string.utf8)
					case let number as NSNumber: txt[key] = Data(number.stringValue.utf8)
					default: txt[key] = Data(String(describing: value).utf8)
					}
				}
			}
		}

		onReady(Advertisement(serviceID: service, port: port, txtRecord: txt))

		// 3. Wait for the device to connect.
		let clientFD = accept(listenFD, nil, nil)
		guard clientFD >= 0 else {
			_lock.lock(); let wasCancelled = _cancelled; _lock.unlock()
			throw wasCancelled ? Failure.cancelled : Failure.socket(String(cString: strerror(errno)))
		}
		defer { close(clientFD) }

		// 4. Pair-setup with the PIN.
		let box = Unmanaged.passRetained(PinBox(onPin)).toOpaque()
		defer { Unmanaged<PinBox>.fromOpaque(box).release() }

		var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
		var pairingFile: OpaquePointer?
		let pinCallback: PairableHostPinCb = { pin, context in
			guard let pin, let context else { return }
			Unmanaged<PinBox>.fromOpaque(context).takeUnretainedValue().handler(String(cString: pin))
		}
		if let err = pairable_host_accept_fd(handle, clientFD, pinCallback, box, &peer, &pairingFile) {
			throw Self._failure(err)
		}
		defer {
			if let peer { rppairing_peer_device_free(peer) }
			if let pairingFile { rp_pairing_file_free(pairingFile) }
		}

		// 5. Save the pairing file.
		try? FileManager.default.removeItem(at: pairingFileURL)
		if let err = rp_pairing_file_write(pairingFile, pairingFileURL.path) {
			throw Self._failure(err)
		}

		func string(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
			ptr.map { String(cString: $0) } ?? ""
		}
		return Result(
			udid: string(peer?.pointee.udid),
			deviceName: string(peer?.pointee.name),
			model: string(peer?.pointee.model),
			pairingFileURL: pairingFileURL
		)
	}

	private func cancelListening() {
		_lock.lock()
		let fd = _listenFD
		_listenFD = -1
		_lock.unlock()
		if fd >= 0 { close(fd) }
	}

	private static func _failure(_ err: UnsafeMutablePointer<IdeviceFfiError>) -> Failure {
		let message = err.pointee.message.map { String(cString: $0) } ?? "code \(err.pointee.code)"
		idevice_error_free(err)
		return .idevice(message)
	}

	private final class PinBox {
		let handler: (String) -> Void
		init(_ handler: @escaping (String) -> Void) { self.handler = handler }
	}
}
