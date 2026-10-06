//
//  ODQRScannerView.swift
//  Odysseus
//
//  Scan a QR code that contains a source URL.
//

import SwiftUI
import VisionKit

struct ODQRScannerView: View {
	var onFound: (String) -> Void
	@Environment(\.dismiss) private var _dismiss

	var body: some View {
		NavigationStack {
			Group {
				if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
					_Scanner { value in
						ODTheme.success()
						onFound(value)
						_dismiss()
					}
					.ignoresSafeArea()
				} else {
					ODEmptyStateView(
						systemImage: "qrcode.viewfinder",
						title: .localized("Can't scan here"),
						message: .localized("QR scanning needs camera access and a device with an A12 chip or newer.")
					)
				}
			}
			.background(Color.black.ignoresSafeArea())
			.navigationTitle(.localized("Scan Source QR Code"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(.localized("Cancel")) { _dismiss() }
				}
			}
		}
	}

	private struct _Scanner: UIViewControllerRepresentable {
		var onFound: (String) -> Void

		func makeUIViewController(context: Context) -> DataScannerViewController {
			let controller = DataScannerViewController(
				recognizedDataTypes: [.barcode(symbologies: [.qr])],
				qualityLevel: .balanced,
				isHighlightingEnabled: true
			)
			controller.delegate = context.coordinator
			try? controller.startScanning()
			return controller
		}

		func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

		func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

		final class Coordinator: NSObject, DataScannerViewControllerDelegate {
			let onFound: (String) -> Void
			private var _done = false

			init(onFound: @escaping (String) -> Void) {
				self.onFound = onFound
			}

			func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
				guard !_done else { return }
				for item in addedItems {
					if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
						_done = true
						dataScanner.stopScanning()
						onFound(value)
						return
					}
				}
			}
		}
	}
}
