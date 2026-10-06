//
//  AboutView.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import SwiftUI
import NimbleViews
import NimbleJSON

// MARK: - Extension: Model
extension AboutView {
	struct CreditsModel: Codable, Hashable {
		let name: String?
		let desc: String?
		let github: String
	}
}

// MARK: - View
struct AboutView: View {
	@State private var _credits: [CreditsModel] = [
		.init(name: "mbakis", desc: "Odysseus", github: "mirazbakis"),
		.init(name: "Samara", desc: "Feather (original app)", github: "khcrysalis"),
		.init(name: "Frizzle", desc: "FreeSign", github: "FrizzleM"),
		.init(name: "SideStore", desc: "SideSign (Apple ID signing, AGPL-3.0)", github: "SideStore"),
		.init(name: "Magesh K", desc: "SideSign, CodeSignKit, AnisetteKit", github: "mahee96"),
		.init(name: "zhlynn", desc: "zsign", github: "zhlynn"),
		.init(name: "jkcoxson", desc: "idevice", github: "jkcoxson"),
		.init(name: "Lakhan Lothiyi", desc: "AltStore Repositories", github: "llsc12"),
		.init(name: "LiveContainer", desc: "Mach-O patches", github: "LiveContainer"),
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("About")) {
			Section {
				VStack {
					FRAppIconView(size: 72)
					
					Text(Bundle.main.name)
						.font(.largeTitle)
						.bold()
						.foregroundStyle(Color.accentColor)
					
					HStack(spacing: 4) {
						Text(.localized("Version"))
						Text(Bundle.main.version)
					}
					.font(.footnote)
					.foregroundStyle(.secondary)
				}
			}
			.frame(maxWidth: .infinity)
			.listRowBackground(EmptyView())
			
			Section {
				Text(verbatim: "An app by mbakis. Odysseus is based on Feather by Samara and FreeSign by Frizzle, and is licensed under the GPL-3.0. Apple ID signing uses SideSign from SideStore, licensed under the AGPL-3.0. Source code: github.com/mirazbakis/Odysseus")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			
			NBSection(.localized("Credits")) {
				ForEach(_credits, id: \.github) { credit in
					_credit(name: credit.name, desc: credit.desc, github: credit.github)
				}
				.transition(.slide)
			}
		}
	}
}

// MARK: - Extension: view
extension AboutView {
	@ViewBuilder
	private func _credit(
		name: String?,
		desc: String?,
		github: String
	) -> some View {
		Button {
			UIApplication.open("https://github.com/\(github)")
		} label: {
			HStack {
				FRIconCellView(
					title: name ?? github,
					subtitle: desc ?? "",
					iconUrl: URL(string: "https://github.com/\(github).png")!,
					size: 45,
					isCircle: true
				)
				
				Image(systemName: "arrow.up.right")
					.foregroundColor(.secondary.opacity(0.65))
			}
		}
	}
}
