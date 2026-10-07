//
//  AppearanceTintColorView.swift
//  Feather
//
//  Created by samara on 14.06.2025.
//

import SwiftUI

// MARK: - View
struct AppearanceTintColorView: View {
	@AppStorage("Feather.userTintColor") private var _selectedColorHex: String = "#B8CCF0"
	private let _tintOptions: [(name: String, hex: String)] = [
		("Moonlight", 		"#B8CCF0"),
		("Aegean", 			"#4F9DE0"),
		("Ithaca Gold", 	"#D9B26F"),
		("Olive", 			"#9CC58A"),
		("Wine-Dark Sea", 	"#B35A7A"),
		("Athena", 			"#9C8CF0"),
		("Sirens", 			"#62D2C4"),
		("Ember", 			"#F08A5D"),
		("Pearl", 			"#E8E8EE")
	]
	// MARK: Body
	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			LazyHGrid(rows: [GridItem(.fixed(100))], spacing: 12) {
				ForEach(_tintOptions, id: \.hex) { option in
					let color = Color(hex: option.hex)
					let cornerRadius = {
						if #available(iOS 26.0, *) {
							28.0
						} else {
							10.5
						}
					}()
					VStack(spacing: 8) {
						Circle()
							.fill(color)
							.frame(width: 30, height: 30)
							.overlay(
								Circle()
									.strokeBorder(Color.black.opacity(0.3), lineWidth: 2)
							)

						Text(option.name)
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					.frame(width: 120, height: 100)
					.background(Color(uiColor: .secondarySystemGroupedBackground))
					.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
					.overlay(
						RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
							.strokeBorder(_selectedColorHex == option.hex ? color : .clear, lineWidth: 2)
					)
					.onTapGesture {
						_selectedColorHex = option.hex
					}
					.accessibilityLabel(Text(option.name))
				}
			}
		}
		.onChange(of: _selectedColorHex) { value in
			UIApplication.topViewController()?.view.window?.tintColor = UIColor(Color(hex: value))
		}
	}
}
