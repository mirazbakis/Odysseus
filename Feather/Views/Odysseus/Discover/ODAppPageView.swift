//
//  ODAppPageView.swift
//  Odysseus
//
//  App page: hero with Get, which source to get it from, screenshots,
//  what's new, description, version history and details.
//

import SwiftUI
import AltSourceKit
import NukeUI

struct ODAppPageView: View {
	let entry: ODCatalogApp

	@State private var _selectedOfferID: String?
	@State private var _isDescriptionExpanded = false
	@State private var _previewScreenshot: ODScreenshotRoute?

	private var _offer: ODCatalogOffer {
		entry.offers.first(where: { $0.id == _selectedOfferID }) ?? entry.primary
	}

	private var _app: ASRepository.App { _offer.app }

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 26) {
				_hero
				if entry.offers.count > 1 {
					_sourcePicker
				}
				if let screenshots = _screenshots, !screenshots.isEmpty {
					_screenshotsRow(screenshots)
				}
				if let version = _app.currentVersion, let notes = _app.currentAppVersion?.localizedDescription ?? _app.versionDescription {
					_whatsNew(version: version, text: notes)
				}
				if let description = _app.localizedDescription ?? _app.description {
					_description(description)
				}
				if let versions = _app.versions, versions.count > 1 {
					_history(versions)
				}
				_details
			}
			.padding(20)
		}
		.odPageBackground()
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				ODRemoteIcon(url: _app.iconURL, size: 28)
			}
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					if let url = _app.currentDownloadUrl {
						Button(.localized("Copy Download Link"), systemImage: "link") {
							UIPasteboard.general.string = url.absoluteString
						}
						Button(.localized("Download Only"), systemImage: "arrow.down.circle") {
							_ = DownloadManager.shared.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
						}
					}
					Button(.localized("Share"), systemImage: "square.and.arrow.up") {
						let text = "\(_app.currentName) \(_app.currentVersion ?? "")\n\(_offer.repository.website?.absoluteString ?? _offer.sourceName)"
						UIActivityViewController.show(activityItems: [text])
					}
				} label: {
					Image(systemName: "ellipsis.circle")
				}
			}
		}
		.sheet(item: $_previewScreenshot) { route in
			ODScreenshotViewer(urls: route.urls, index: route.index)
		}
	}

	private var _screenshots: [URL]? {
		if UIDevice.current.userInterfaceIdiom == .pad, let ipad = _app.screenshots?.iPad, !ipad.isEmpty {
			return ipad
		}
		return _app.screenshotURLs ?? _app.screenshots?.iPhone
	}

	// MARK: Hero
	private var _hero: some View {
		HStack(alignment: .top, spacing: 16) {
			ODRemoteIcon(url: _app.iconURL, size: 112)

			VStack(alignment: .leading, spacing: 4) {
				Text(_app.currentName)
					.font(.system(.title2, design: .rounded).weight(.bold))
					.foregroundStyle(.white)
					.lineLimit(2)

				Text(_app.developer ?? _offer.sourceName)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.lineLimit(1)

				Spacer(minLength: 8)

				HStack(spacing: 10) {
					ODGetButton(app: _app, prominent: true)
					if let size = _app.size {
						Text(size.formattedByteCount)
							.font(.system(.caption, design: .rounded).weight(.semibold))
							.foregroundStyle(.secondary)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	// MARK: Source picker
	private var _sourcePicker: some View {
		VStack(alignment: .leading, spacing: 8) {
			ODSectionHeader(
				title: .localized("Available from %lld sources", arguments: entry.sourceCount),
				subtitle: .localized("Pick which one to get it from")
			)
			VStack(spacing: 0) {
				ForEach(entry.offers) { offer in
					Button {
						ODTheme.lightImpact()
						_selectedOfferID = offer.id
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(offer.sourceName)
									.font(.subheadline.weight(.semibold))
									.foregroundStyle(.white)
								Text(verbatim: [offer.app.currentVersion.map { "v\($0)" }, offer.app.currentDate.map { DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .none) }]
									.compactMap { $0 }
									.joined(separator: " · "))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							if offer.id == _offer.id {
								Image(systemName: "checkmark.circle.fill")
									.foregroundStyle(Color.accentColor)
							}
						}
						.padding(.horizontal, 14)
						.padding(.vertical, 10)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					if offer.id != entry.offers.last?.id {
						Divider().padding(.leading, 14)
					}
				}
			}
			.odCard(padding: 0)
		}
	}

	// MARK: Screenshots
	private func _screenshotsRow(_ urls: [URL]) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			ODSectionHeader(title: .localized("Preview"))
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 12) {
					ForEach(urls.indices, id: \.self) { index in
						Button {
							_previewScreenshot = ODScreenshotRoute(urls: urls, index: index)
						} label: {
							LazyImage(url: urls[index]) { state in
								if let image = state.image {
									image
										.resizable()
										.aspectRatio(contentMode: .fit)
								} else {
									RoundedRectangle(cornerRadius: 18, style: .continuous)
										.fill(ODTheme.navy)
										.frame(width: 190)
								}
							}
							.frame(height: 400)
							.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
							.overlay(
								RoundedRectangle(cornerRadius: 18, style: .continuous)
									.strokeBorder(ODTheme.hairline, lineWidth: 1)
							)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 20)
			}
			.padding(.horizontal, -20)
		}
	}

	// MARK: What's new
	private func _whatsNew(version: String, text: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			ODSectionHeader(title: .localized("What's New"))
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Text(verbatim: .localized("Version %@", arguments: version))
						.font(.system(.subheadline, design: .rounded).weight(.semibold))
						.foregroundStyle(.secondary)
					Spacer()
					if let date = _app.currentDate?.date {
						Text(date, style: .date)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Text(text)
					.font(.subheadline)
					.foregroundStyle(.white.opacity(0.92))
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.odCard()
		}
	}

	// MARK: Description
	private func _description(_ text: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			ODSectionHeader(title: .localized("About"))
			VStack(alignment: .leading, spacing: 8) {
				Text(text)
					.font(.subheadline)
					.foregroundStyle(.white.opacity(0.92))
					.lineLimit(_isDescriptionExpanded ? nil : 5)
				Button(_isDescriptionExpanded ? String.localized("Less") : String.localized("More")) {
					withAnimation(.snappy) { _isDescriptionExpanded.toggle() }
				}
				.font(.system(.subheadline, design: .rounded).weight(.semibold))
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.odCard()
		}
	}

	// MARK: Version history
	private func _history(_ versions: [ASRepository.App.Version]) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			ODSectionHeader(title: .localized("Version History"))
			VStack(spacing: 0) {
				ForEach(Array(versions.prefix(6).enumerated()), id: \.offset) { index, version in
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Text(verbatim: version.version)
								.font(.subheadline.weight(.semibold))
								.foregroundStyle(.white)
							Spacer()
							if let date = version.date?.date {
								Text(date, style: .date)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						if let notes = version.localizedDescription, !notes.isEmpty {
							Text(notes)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(3)
						}
					}
					.padding(14)
					if index < min(versions.count, 6) - 1 {
						Divider().padding(.leading, 14)
					}
				}
			}
			.odCard(padding: 0)
		}
	}

	// MARK: Details
	private var _details: some View {
		VStack(alignment: .leading, spacing: 8) {
			ODSectionHeader(title: .localized("Information"))
			VStack(spacing: 0) {
				_row(.localized("Source"), _offer.sourceName)
				if let developer = _app.developer { _row(.localized("Developer"), developer) }
				if let bundle = _app.id { _row(.localized("Bundle ID"), bundle) }
				if let version = _app.currentVersion { _row(.localized("Version"), version) }
				if let size = _app.size { _row(.localized("Size"), size.formattedByteCount) }
				if let category = _app.category {
					_row(.localized("Category"), ODCategory.known.first(where: { $0.id == category.lowercased() })?.name ?? category.capitalized)
				}
				if let minOS = _app.currentAppVersion?.minOSVersion { _row(.localized("Requires"), "iOS \(minOS.description)") }
				if let date = _app.currentDate?.date {
					_row(.localized("Updated"), DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
				}
			}
			.odCard(padding: 4)
		}
	}

	private func _row(_ title: String, _ value: String) -> some View {
		HStack(alignment: .top) {
			Text(title)
				.font(.subheadline)
				.foregroundStyle(.secondary)
			Spacer(minLength: 16)
			Text(value)
				.font(.subheadline.weight(.medium))
				.foregroundStyle(.white)
				.multilineTextAlignment(.trailing)
				.lineLimit(2)
				.textSelection(.enabled)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 11)
	}
}

// MARK: - Screenshot viewer
struct ODScreenshotRoute: Identifiable {
	let urls: [URL]
	let index: Int
	var id: Int { index }
}

struct ODScreenshotViewer: View {
	let urls: [URL]
	@State var index: Int
	@Environment(\.dismiss) private var _dismiss

	var body: some View {
		NavigationStack {
			TabView(selection: $index) {
				ForEach(urls.indices, id: \.self) { i in
					LazyImage(url: urls[i]) { state in
						if let image = state.image {
							image.resizable().aspectRatio(contentMode: .fit)
						} else {
							ProgressView()
						}
					}
					.padding()
					.tag(i)
				}
			}
			.tabViewStyle(.page)
			.background(Color.black.ignoresSafeArea())
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(.localized("Done")) { _dismiss() }
				}
			}
		}
	}
}
