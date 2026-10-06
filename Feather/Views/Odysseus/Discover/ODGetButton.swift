//
//  ODGetButton.swift
//  Odysseus
//
//  App Store style GET button: one tap downloads, signs and installs.
//  Shows a progress ring while downloading and a spinner while signing.
//

import SwiftUI
import Combine
import NukeUI
import AltSourceKit

struct ODGetButton: View {
	let app: ASRepository.App
	var prominent: Bool = false

	@ObservedObject private var _downloadManager = DownloadManager.shared
	@ObservedObject private var _pipeline = ODSignPipeline.shared
	@State private var _progress: Double = 0
	@State private var _cancellable: AnyCancellable?

	private var _id: String { app.currentUniqueId }

	var body: some View {
		ZStack {
			if case .signing = _pipeline.phases[_id] {
				HStack(spacing: 6) {
					ProgressView()
						.controlSize(.small)
						.tint(Color.accentColor)
					if prominent {
						Text(.localized("Signing…"))
							.font(.system(.subheadline, design: .rounded).weight(.semibold))
							.foregroundStyle(Color.accentColor)
					}
				}
				.frame(minWidth: 30, minHeight: 30)
				.transition(.opacity)
			} else if let download = _downloadManager.getDownload(by: _id) {
				ZStack {
					Circle()
						.stroke(Color.accentColor.opacity(0.2), lineWidth: 2.5)
					Circle()
						.trim(from: 0, to: max(0.02, _progress))
						.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.animation(.smooth, value: _progress)
					Image(systemName: _progress >= 0.7 ? "shippingbox.fill" : "stop.fill")
						.foregroundStyle(Color.accentColor)
						.font(.system(size: 10, weight: .bold))
				}
				.frame(width: 30, height: 30)
				.contentShape(Circle())
				.onTapGesture {
					// Unpacking has started past this point, let it finish.
					if _progress < 0.7 {
						_pipeline.cancelGet(download.id)
					}
				}
				.transition(.opacity)
			} else if case .failed(let message) = _pipeline.phases[_id] {
				Button {
					_pipeline.clearFailure(_id)
					_get()
				} label: {
					Label(.localized("Retry"), systemImage: "arrow.clockwise")
						.labelStyle(.titleOnly)
				}
				.buttonStyle(ODCapsuleButtonStyle(filled: false))
				.accessibilityHint(Text(message))
			} else {
				Button(action: _get) {
					Text(.localized("Get"))
						.textCase(.uppercase)
						.frame(minWidth: prominent ? 64 : nil)
				}
				.buttonStyle(ODCapsuleButtonStyle(filled: prominent))
				.disabled(app.currentDownloadUrl == nil)
				.transition(.opacity)
			}
		}
		.onAppear(perform: _observe)
		.onDisappear { _cancellable?.cancel() }
		.onChange(of: _downloadManager.downloads.count) { _ in _observe() }
		.animation(.easeInOut(duration: 0.25), value: _downloadManager.getDownload(by: _id) != nil)
		.animation(.easeInOut(duration: 0.25), value: _pipeline.phases[_id])
	}

	private func _get() {
		ODTheme.lightImpact()
		_pipeline.get(app)
	}

	private func _observe() {
		_cancellable?.cancel()
		guard let download = _downloadManager.getDownload(by: _id) else {
			_progress = 0
			return
		}
		_progress = download.overallProgress
		_cancellable = Publishers.CombineLatest(download.$progress, download.$unpackageProgress)
			.receive(on: RunLoop.main)
			.sink { _, _ in _progress = download.overallProgress }
	}
}

// MARK: - Remote icon
struct ODRemoteIcon: View {
	let url: URL?
	var size: CGFloat = 56

	var body: some View {
		Group {
			if let url {
				LazyImage(url: url) { state in
					if let image = state.image {
						image.appIconStyle(size: size)
					} else {
						_placeholder
					}
				}
			} else {
				_placeholder
			}
		}
		.frame(width: size, height: size)
	}

	private var _placeholder: some View {
		RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
			.fill(ODTheme.navyRaised)
			.frame(width: size, height: size)
			.overlay(
				Image(systemName: "app.dashed")
					.font(.system(size: size * 0.38))
					.foregroundStyle(.secondary)
			)
	}
}
