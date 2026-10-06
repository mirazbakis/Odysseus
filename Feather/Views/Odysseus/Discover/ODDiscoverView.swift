//
//  ODDiscoverView.swift
//  Odysseus
//
//  The store front: featured carousel, New & Updated, Recently Added,
//  categories and a row per source, built from every source you've
//  added.
//

import SwiftUI
import AltSourceKit
import NukeUI

struct ODDiscoverView: View {
	/// On iOS 16/17 search lives here; on iOS 18+ it's its own tab.
	var showsSearch: Bool = false

	@StateObject private var _store = ODCatalogStore.shared
	@State private var _searchText = ""
	@State private var _isAddingSource = false
	@AppStorage(ODPrefs.discoverRowOrder) private var _rowOrderRaw: String = ""

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	var body: some View {
		NavigationStack {
			Group {
				if _sources.isEmpty {
					ODEmptyStateView(
						systemImage: "sailboat",
						title: .localized("Set sail"),
						message: .localized("Add a source and every app it offers shows up here, all in one place."),
						actionTitle: .localized("Add a Source")
					) {
						_isAddingSource = true
					}
				} else if _store.catalog.isEmpty {
					_loading
				} else if showsSearch && !_searchText.isEmpty {
					ODSearchResultsList(results: _store.catalog.search(_searchText), query: _searchText)
				} else {
					_storeFront
				}
			}
			.odPageBackground()
			.navigationTitle(.localized("Discover"))
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						_isAddingSource = true
					} label: {
						Image(systemName: "plus")
					}
					.accessibilityLabel(.localized("Add Source"))
				}
			}
			.modifier(_OptionalSearchable(isOn: showsSearch, text: $_searchText))
			.refreshable {
				await _store.load(force: true)
			}
			.navigationDestination(for: ODCatalogApp.self) { app in
				ODAppPageView(entry: app)
			}
			.navigationDestination(for: ODCategory.self) { category in
				ODAppListView(
					title: category.name,
					apps: _store.catalog.apps(in: category)
				)
			}
			.navigationDestination(for: ODSourceRoute.self) { route in
				if let source = _store.catalog.sources.first(where: { $0.id == route.id }) {
					ODAppListView(title: source.name, apps: source.apps)
				}
			}
			.sheet(isPresented: $_isAddingSource) {
				SourcesAddView()
			}
		}
		.task(id: _sources.count) {
			await _store.refreshIfNeeded()
		}
	}

	// MARK: Loading
	private var _loading: some View {
		VStack(spacing: 14) {
			if _store.isLoading {
				ProgressView()
				Text(.localized("Loading your sources…"))
					.font(.system(.subheadline, design: .rounded).weight(.medium))
					.foregroundStyle(.secondary)
			} else {
				ODEmptyStateView(
					systemImage: "wifi.exclamationmark",
					title: .localized("Nothing to show"),
					message: .localized("Your sources didn't load. Pull down to try again."),
					actionTitle: .localized("Try Again")
				) {
					Task { await _store.load(force: true) }
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: Store front
	private var _rows: [ODPrefs.DiscoverRow] {
		_ = _rowOrderRaw
		return ODPrefs.discoverOrder
	}

	private var _storeFront: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 30) {
				ForEach(_rows) { row in
					_row(row)
				}
				Color.clear.frame(height: 40)
			}
			.padding(.top, 8)
		}
	}

	@ViewBuilder
	private func _row(_ row: ODPrefs.DiscoverRow) -> some View {
		let catalog = _store.catalog
		switch row {
		case .featured:
			if !catalog.featured.isEmpty {
				ODFeaturedCarousel(apps: catalog.featured)
			}
		case .newAndUpdated:
			if !catalog.newAndUpdated.isEmpty {
				ODAppShelf(
					title: row.title,
					subtitle: .localized("Fresh versions from your sources"),
					apps: catalog.newAndUpdated
				)
			}
		case .recentlyAdded:
			if !catalog.recentlyAdded.isEmpty {
				ODAppShelf(
					title: row.title,
					subtitle: .localized("New to your sources"),
					apps: catalog.recentlyAdded
				)
			}
		case .categories:
			if !catalog.categories.isEmpty {
				ODCategoryGrid(categories: catalog.categories)
			}
		case .sources:
			ForEach(catalog.sources) { source in
				ODAppShelf(
					title: source.name,
					subtitle: .localized("%lld apps", arguments: source.apps.count),
					apps: Array(source.apps.prefix(15)),
					seeAll: ODSourceRoute(id: source.id)
				)
			}
		}
	}
}

struct ODSourceRoute: Hashable {
	let id: String
}

private struct _OptionalSearchable: ViewModifier {
	let isOn: Bool
	@Binding var text: String

	func body(content: Content) -> some View {
		if isOn {
			content.searchable(text: $text, prompt: Text(.localized("Apps, developers, bundle IDs")))
		} else {
			content
		}
	}
}

// MARK: - Featured carousel
struct ODFeaturedCarousel: View {
	let apps: [ODCatalogApp]

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ODSectionHeader(title: .localized("Featured"))
				.padding(.horizontal, 20)

			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(spacing: 14) {
					ForEach(apps) { app in
						NavigationLink(value: app) {
							ODFeaturedCard(entry: app)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 20)
				.compatScrollTargetLayout()
			}
			.compatScrollTargetBehavior()
		}
	}
}

struct ODFeaturedCard: View {
	let entry: ODCatalogApp

	private var _tint: Color {
		entry.app.tintColor ?? entry.repository.tintColor ?? Color(hex: "#3A5578")
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ZStack(alignment: .topLeading) {
				LinearGradient(
					colors: [_tint.opacity(0.95), _tint.opacity(0.45), ODTheme.navy],
					startPoint: .topLeading,
					endPoint: .bottomTrailing
				)

				if let screenshot = entry.app.screenshotURLs?.first {
					LazyImage(url: screenshot) { state in
						if let image = state.image {
							image
								.resizable()
								.scaledToFill()
								.opacity(0.35)
						}
					}
					.allowsHitTesting(false)
				}

				Text(entry.primary.sourceName)
					.font(.system(.caption2, design: .rounded).weight(.bold))
					.textCase(.uppercase)
					.foregroundStyle(.white.opacity(0.9))
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.odGlassCapsule(interactive: false)
					.padding(12)
			}
			.frame(height: 150)
			.clipped()

			HStack(spacing: 12) {
				ODRemoteIcon(url: entry.app.iconURL, size: 52)

				VStack(alignment: .leading, spacing: 2) {
					Text(entry.app.currentName)
						.font(.system(.headline, design: .rounded).weight(.bold))
						.foregroundStyle(.white)
						.lineLimit(1)
					Text(entry.app.currentDescription ?? entry.app.developer ?? "")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				.frame(maxWidth: .infinity, alignment: .leading)

				ODGetButton(app: entry.app)
			}
			.padding(14)
			.background(ODTheme.navy)
		}
		.frame(width: 300)
		.clipShape(RoundedRectangle(cornerRadius: ODTheme.cardRadius, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: ODTheme.cardRadius, style: .continuous)
				.strokeBorder(ODTheme.hairline, lineWidth: 1)
		)
	}
}

// MARK: - Shelf (horizontal, 3 rows per page like the App Store)
struct ODAppShelf: View {
	let title: String
	var subtitle: String? = nil
	let apps: [ODCatalogApp]
	var seeAll: ODSourceRoute? = nil

	private var _pages: [[ODCatalogApp]] {
		stride(from: 0, to: apps.count, by: 3).map { Array(apps[$0..<min($0 + 3, apps.count)]) }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .firstTextBaseline) {
				ODSectionHeader(title: title, subtitle: subtitle)
				if let seeAll {
					NavigationLink(value: seeAll) {
						Text(.localized("See All"))
							.font(.subheadline.weight(.semibold))
					}
				}
			}
			.padding(.horizontal, 20)

			ScrollView(.horizontal, showsIndicators: false) {
				LazyHStack(alignment: .top, spacing: 16) {
					ForEach(_pages.indices, id: \.self) { index in
						VStack(spacing: 0) {
							ForEach(_pages[index]) { app in
								ODAppRow(entry: app)
								if app.id != _pages[index].last?.id {
									Divider().padding(.leading, 70)
								}
							}
						}
						.frame(width: 320)
					}
				}
				.padding(.horizontal, 20)
				.compatScrollTargetLayout()
			}
			.compatScrollTargetBehavior()
		}
	}
}

// MARK: - Row
struct ODAppRow: View {
	let entry: ODCatalogApp

	var body: some View {
		HStack(spacing: 12) {
			NavigationLink(value: entry) {
				HStack(spacing: 12) {
					ODRemoteIcon(url: entry.app.iconURL, size: 58)

					VStack(alignment: .leading, spacing: 2) {
						Text(entry.app.currentName)
							.font(.system(.body, design: .rounded).weight(.semibold))
							.foregroundStyle(.white)
							.lineLimit(1)
						Text(entry.app.currentDescription ?? entry.app.developer ?? entry.primary.sourceName)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.lineLimit(1)
						if entry.sourceCount > 1 {
							Text(verbatim: .localized("Available from %lld sources", arguments: entry.sourceCount))
								.font(.caption2.weight(.medium))
								.foregroundStyle(Color.accentColor.opacity(0.85))
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			ODGetButton(app: entry.app)
		}
		.padding(.vertical, 8)
	}
}

// MARK: - Categories
struct ODCategoryGrid: View {
	let categories: [ODCategory]

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ODSectionHeader(title: .localized("Categories"))
				.padding(.horizontal, 20)

			LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
				ForEach(categories) { category in
					NavigationLink(value: category) {
						HStack(spacing: 10) {
							Image(systemName: category.icon)
								.font(.system(size: 15, weight: .semibold))
								.foregroundStyle(Color.accentColor)
								.frame(width: 30, height: 30)
								.background(Circle().fill(Color.accentColor.opacity(0.12)))
							Text(category.name)
								.font(.system(.subheadline, design: .rounded).weight(.semibold))
								.foregroundStyle(.white)
								.lineLimit(1)
							Spacer(minLength: 0)
						}
						.padding(10)
						.background(
							RoundedRectangle(cornerRadius: ODTheme.chipRadius, style: .continuous)
								.fill(ODTheme.navy)
						)
						.overlay(
							RoundedRectangle(cornerRadius: ODTheme.chipRadius, style: .continuous)
								.strokeBorder(ODTheme.hairline, lineWidth: 1)
						)
					}
					.buttonStyle(.plain)
				}
			}
			.padding(.horizontal, 20)
		}
	}
}

// MARK: - Simple list (category / source / see all)
struct ODAppListView: View {
	let title: String
	let apps: [ODCatalogApp]

	var body: some View {
		ScrollView {
			LazyVStack(spacing: 0) {
				ForEach(apps) { app in
					ODAppRow(entry: app)
					Divider().padding(.leading, 70)
				}
			}
			.padding(.horizontal, 20)
		}
		.odPageBackground()
		.navigationTitle(title)
		.navigationBarTitleDisplayMode(.inline)
		.overlay {
			if apps.isEmpty {
				ODEmptyStateView(systemImage: "tray", title: .localized("No apps"), message: .localized("Nothing here yet."))
			}
		}
	}
}

// MARK: - Search results
struct ODSearchResultsList: View {
	let results: [ODCatalogApp]
	let query: String

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				Text(verbatim: .localized("%lld results", arguments: results.count))
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.secondary)
					.padding(.vertical, 8)
				ForEach(results) { app in
					ODAppRow(entry: app)
					Divider().padding(.leading, 70)
				}
			}
			.padding(.horizontal, 20)
		}
		.scrollDismissesKeyboard(.interactively)
		.overlay {
			if results.isEmpty {
				ODEmptyStateView(
					systemImage: "magnifyingglass",
					title: .localized("No results"),
					message: .localized("Nothing in your sources matches “%@”.", arguments: query)
				)
			}
		}
	}
}

// MARK: - Search tab (iOS 18+)
struct ODSearchView: View {
	@StateObject private var _store = ODCatalogStore.shared
	@State private var _query = ""

	var body: some View {
		NavigationStack {
			Group {
				if _query.isEmpty {
					_suggestions
				} else {
					ODSearchResultsList(results: _store.catalog.search(_query), query: _query)
				}
			}
			.odPageBackground()
			.navigationTitle(.localized("Search"))
			.searchable(text: $_query, prompt: Text(.localized("Apps, developers, bundle IDs")))
			.navigationDestination(for: ODCatalogApp.self) { app in
				ODAppPageView(entry: app)
			}
			.navigationDestination(for: ODCategory.self) { category in
				ODAppListView(title: category.name, apps: _store.catalog.apps(in: category))
			}
		}
	}

	private var _suggestions: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				if !_store.catalog.categories.isEmpty {
					ODCategoryGrid(categories: _store.catalog.categories)
				}
				if !_store.catalog.newAndUpdated.isEmpty {
					ODAppShelf(title: .localized("New & Updated"), apps: Array(_store.catalog.newAndUpdated.prefix(9)))
				}
			}
			.padding(.top, 8)
		}
	}
}
