//
//  ODRootView.swift
//  Odysseus
//
//  Discover · Sources · Library · Settings (+ Search on iOS 18+).
//  iOS 26: Liquid Glass tab bar with a separate round search button.
//  iPad: sidebar.
//

import SwiftUI
import CoreData

enum ODTab: Hashable {
	case discover
	case sources
	case library
	case settings
	case search
}

struct ODRootView: View {
	@State private var _tab: ODTab = .discover
	@State private var _installApp: AnyApp?
	@StateObject private var _downloadManager = DownloadManager.shared

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signed: FetchedResults<Signed>

	var body: some View {
		_tabs
			.overlay(alignment: .bottom) {
				ODDownloadPill(downloadManager: _downloadManager)
					.padding(.bottom, UIDevice.current.userInterfaceIdiom == .pad ? 24 : 70)
			}
			.sheet(item: $_installApp) { app in
				ODInstallSheet(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(320)])
					.presentationDragIndicator(.visible)
			}
			.onReceive(NotificationCenter.default.publisher(for: .odysseusPresentInstall)) { notification in
				// Give Core Data a moment to see the new Signed record.
				let uuid = notification.object as? String
				Task { @MainActor in
					try? await Task.sleep(nanoseconds: 600_000_000)
					_presentInstall(uuid: uuid)
				}
			}
	}

	private func _presentInstall(uuid: String?) {
		if let uuid, let app = _signed.first(where: { $0.uuid == uuid }) {
			_installApp = AnyApp(base: app)
		} else if let uuid {
			let request: NSFetchRequest<Signed> = Signed.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			request.fetchLimit = 1
			if let app = try? Storage.shared.context.fetch(request).first {
				_installApp = AnyApp(base: app)
			}
		} else if let latest = _signed.first {
			_installApp = AnyApp(base: latest)
		}
	}

	@ViewBuilder
	private var _tabs: some View {
		if #available(iOS 18.0, *) {
			TabView(selection: $_tab) {
				Tab(String.localized("Discover"), systemImage: "sparkles", value: ODTab.discover) {
					ODDiscoverView()
				}
				Tab(String.localized("Sources"), systemImage: "globe.desk", value: ODTab.sources) {
					SourcesView()
						.odPageBackground()
				}
				Tab(String.localized("Library"), systemImage: "square.stack.3d.up.fill", value: ODTab.library) {
					ODLibraryView()
				}
				Tab(String.localized("Settings"), systemImage: "gearshape.fill", value: ODTab.settings) {
					ODSettingsView()
				}
				Tab(value: ODTab.search, role: .search) {
					ODSearchView()
				}
			}
			.tabViewStyle(.sidebarAdaptable)
			.modifier(ODTabBarMinimize())
		} else {
			TabView(selection: $_tab) {
				ODDiscoverView(showsSearch: true)
					.tabItem { Label(.localized("Discover"), systemImage: "sparkles") }
					.tag(ODTab.discover)
				SourcesView()
					.odPageBackground()
					.tabItem { Label(.localized("Sources"), systemImage: "globe.desk") }
					.tag(ODTab.sources)
				ODLibraryView()
					.tabItem { Label(.localized("Library"), systemImage: "square.stack.3d.up.fill") }
					.tag(ODTab.library)
				ODSettingsView()
					.tabItem { Label(.localized("Settings"), systemImage: "gearshape.fill") }
					.tag(ODTab.settings)
			}
		}
	}
}

/// iOS 26: tab bar shrinks while scrolling down.
private struct ODTabBarMinimize: ViewModifier {
	func body(content: Content) -> some View {
		if #available(iOS 26.0, *) {
			content.tabBarMinimizeBehavior(.onScrollDown)
		} else {
			content
		}
	}
}

// MARK: - Floating download pill (Liquid Glass)
struct ODDownloadPill: View {
	@ObservedObject var downloadManager: DownloadManager
	@ObservedObject private var _pipeline = ODSignPipeline.shared

	private var _signingCount: Int {
		_pipeline.phases.values.filter { $0 == .signing }.count
	}

	var body: some View {
		ZStack {
			if let download = downloadManager.downloads.first {
				ODDownloadPillContent(download: download, extraCount: downloadManager.downloads.count - 1)
					.transition(.move(edge: .bottom).combined(with: .opacity))
			} else if _signingCount > 0 {
				HStack(spacing: 10) {
					ProgressView()
						.tint(Color.accentColor)
					Text(verbatim: _signingCount == 1 ? String.localized("Signing…") : String.localized("Signing %lld apps…", arguments: _signingCount))
						.font(.system(.footnote, design: .rounded).weight(.semibold))
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 11)
				.odGlassCapsule()
				.transition(.move(edge: .bottom).combined(with: .opacity))
			}
		}
		.animation(.spring(response: 0.35, dampingFraction: 0.85), value: downloadManager.downloads.count)
		.animation(.spring(response: 0.35, dampingFraction: 0.85), value: _signingCount)
	}
}

private struct ODDownloadPillContent: View {
	let download: Download
	let extraCount: Int

	@State private var _progress: Double = 0
	@State private var _unpack: Double = 0

	private var _overall: Double {
		download.onlyArchiving ? _unpack : (0.3 * _unpack) + (0.7 * _progress)
	}

	var body: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
				Circle()
					.trim(from: 0, to: max(0.03, _overall))
					.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
					.rotationEffect(.degrees(-90))
					.animation(.smooth, value: _overall)
				Image(systemName: "arrow.down")
					.font(.caption2.weight(.bold))
					.foregroundStyle(Color.accentColor)
			}
			.frame(width: 28, height: 28)

			VStack(alignment: .leading, spacing: 1) {
				Text(download.onlyArchiving ? String.localized("Adding to Library…") : String.localized("Downloading %@", arguments: download.fileName))
					.font(.system(.footnote, design: .rounded).weight(.semibold))
					.lineLimit(1)
				Text(verbatim: "\(Int(_overall * 100))%")
					.font(.caption2)
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}

			if extraCount > 0 {
				Text(verbatim: "+\(extraCount)")
					.font(.caption2.weight(.bold))
					.foregroundStyle(.secondary)
					.padding(6)
					.background(Circle().fill(ODTheme.navyRaised))
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.odGlassCapsule()
		.shadow(color: .black.opacity(0.4), radius: 14, y: 6)
		.padding(.horizontal, 24)
		.onReceive(download.$progress) { _progress = $0 }
		.onReceive(download.$unpackageProgress) { _unpack = $0 }
	}
}
