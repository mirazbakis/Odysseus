//
//  ODCatalogStore.swift
//  Odysseus
//
//  Keeps the combined catalog up to date as sources load, and
//  refreshes sources on the schedule set in Settings.
//

import Foundation
import Combine
import SwiftUI
import AltSourceKit

@MainActor
final class ODCatalogStore: ObservableObject {
	static let shared = ODCatalogStore()

	@Published private(set) var catalog = ODCatalog()
	@Published private(set) var isLoading = false

	private let _viewModel = SourcesViewModel.shared
	private var _cancellables = Set<AnyCancellable>()

	private init() {
		_viewModel.$sources
			.debounce(for: .milliseconds(150), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?.rebuild() }
			.store(in: &_cancellables)

		NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.debounce(for: .milliseconds(300), scheduler: RunLoop.main)
			.sink { [weak self] _ in self?._rebuildIfSettingsChanged() }
			.store(in: &_cancellables)
	}

	private var _lastSettingsSignature = ""

	private var _settingsSignature: String {
		let defaults = UserDefaults.standard
		return "\(defaults.bool(forKey: ODPrefs.combineDuplicates))|\(defaults.string(forKey: ODPrefs.discoverHiddenSources) ?? "")"
	}

	private func _rebuildIfSettingsChanged() {
		guard _settingsSignature != _lastSettingsSignature else { return }
		rebuild()
	}

	func rebuild() {
		_lastSettingsSignature = _settingsSignature
		let loaded = _viewModel.sources
			.map { (source: $0.key, repository: $0.value) }
			.sorted { ($0.source.name ?? "").localizedCaseInsensitiveCompare($1.source.name ?? "") == .orderedAscending }

		catalog = ODCatalog.build(
			from: loaded,
			combineDuplicates: UserDefaults.standard.bool(forKey: ODPrefs.combineDuplicates),
			hiddenSourceIDs: ODPrefs.hiddenSourceIDs
		)
	}

	/// Loads every source. With `force`, re-downloads all of them.
	func load(force: Bool = false) async {
		let sources = Storage.shared.getSources()
		guard !sources.isEmpty else {
			rebuild()
			return
		}
		isLoading = true
		await _viewModel.fetchSources(sources, refresh: force)
		isLoading = false
		rebuild()
	}

	/// Refreshes when the auto-refresh interval has passed.
	func refreshIfNeeded() async {
		let hours = UserDefaults.standard.integer(forKey: ODPrefs.sourceAutoRefreshHours)
		let last = UserDefaults.standard.double(forKey: ODPrefs.sourcesLastRefresh)
		let due = hours > 0 && Date().timeIntervalSince1970 - last > Double(hours) * 3600
		await load(force: due)
	}
}
