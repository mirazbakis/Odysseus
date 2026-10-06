//
//  ODTheme.swift
//  Odysseus
//
//  Midnight design system: pure black background, very dark navy
//  cards, moonlight silver-blue accent, Liquid Glass on iOS 26.
//

import SwiftUI
import UIKit
import AltSourceKit

// MARK: - Theme
enum ODTheme {
	/// Pure black.
	static let midnight = Color(hex: "#000000")
	/// Very dark navy for cards.
	static let navy = Color(hex: "#060A14")
	/// Raised chips, fields and rows.
	static let navyRaised = Color(hex: "#0B1222")
	/// Hairline borders on cards.
	static let hairline = Color.white.opacity(0.06)
	/// Default accent: moonlight silver-blue.
	static let moonlightHex = "#B8CCF0"

	static let cardRadius: CGFloat = 22
	static let chipRadius: CGFloat = 14

	static var accent: Color {
		Color(hex: UserDefaults.standard.string(forKey: "Feather.userTintColor") ?? moonlightHex)
	}

	/// The brand gradient used behind the logo.
	static let logoGradient = LinearGradient(
		colors: [Color(hex: "#3A5578"), Color(hex: "#16213A"), Color(hex: "#03050B")],
		startPoint: .top,
		endPoint: .bottom
	)

	static let valid = Color(hex: "#3DDC84")
	static let revoked = Color(hex: "#FF5A5F")
	static let couldntCheck = Color(hex: "#FFA43A")
	static let unknown = Color(hex: "#8E8E93")

	static func lightImpact() {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
	}

	static func success() {
		UINotificationFeedbackGenerator().notificationOccurred(.success)
	}

	static func warning() {
		UINotificationFeedbackGenerator().notificationOccurred(.warning)
	}

	static func failure() {
		UINotificationFeedbackGenerator().notificationOccurred(.error)
	}
}

// MARK: - Background
struct ODBackground: View {
	var body: some View {
		ODTheme.midnight.ignoresSafeArea()
	}
}

extension View {
	/// Pure black page background that also hides list/scroll backgrounds.
	func odPageBackground() -> some View {
		self
			.scrollContentBackground(.hidden)
			.background(ODBackground())
	}

	/// Navy row background for Form / List sections.
	func odRowBackground() -> some View {
		self.listRowBackground(ODTheme.navy)
	}
}

// MARK: - Card
struct ODCardModifier: ViewModifier {
	var padding: CGFloat = 16
	var raised: Bool = false

	func body(content: Content) -> some View {
		content
			.padding(padding)
			.background(
				RoundedRectangle(cornerRadius: ODTheme.cardRadius, style: .continuous)
					.fill(raised ? ODTheme.navyRaised : ODTheme.navy)
			)
			.overlay(
				RoundedRectangle(cornerRadius: ODTheme.cardRadius, style: .continuous)
					.strokeBorder(ODTheme.hairline, lineWidth: 1)
			)
	}
}

extension View {
	func odCard(padding: CGFloat = 16, raised: Bool = false) -> some View {
		modifier(ODCardModifier(padding: padding, raised: raised))
	}
}

// MARK: - Liquid Glass helpers
extension View {
	/// Liquid Glass capsule on iOS 26, material capsule before.
	@ViewBuilder
	func odGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
		if #available(iOS 26.0, *) {
			if let tint {
				self.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: .capsule)
			} else {
				self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
			}
		} else {
			self.background(
				Capsule()
					.fill(.ultraThinMaterial)
					.overlay(Capsule().fill((tint ?? .clear).opacity(0.35)))
					.overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
			)
		}
	}

	/// Liquid Glass circle on iOS 26, material circle before.
	@ViewBuilder
	func odGlassCircle() -> some View {
		if #available(iOS 26.0, *) {
			self.glassEffect(.regular.interactive(), in: .circle)
		} else {
			self.background(
				Circle()
					.fill(.ultraThinMaterial)
					.overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
			)
		}
	}
}

// MARK: - Buttons
/// Big rounded call to action.
struct ODProminentButtonStyle: ButtonStyle {
	var isDestructive: Bool = false

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(.headline, design: .rounded).weight(.bold))
			.foregroundStyle(isDestructive ? Color.white : Color.black)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 15)
			.background(
				Capsule()
					.fill(isDestructive ? AnyShapeStyle(ODTheme.revoked) : AnyShapeStyle(Color.accentColor))
			)
			.opacity(configuration.isPressed ? 0.75 : 1)
			.scaleEffect(configuration.isPressed ? 0.985 : 1)
			.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
	}
}

/// App Store style "GET" capsule.
struct ODCapsuleButtonStyle: ButtonStyle {
	var filled: Bool = false

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(.subheadline, design: .rounded).weight(.bold))
			.foregroundStyle(filled ? Color.black : Color.accentColor)
			.padding(.horizontal, 20)
			.padding(.vertical, 7)
			.background(
				Capsule().fill(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(ODTheme.navyRaised))
			)
			.overlay(Capsule().strokeBorder(filled ? Color.clear : Color.accentColor.opacity(0.18), lineWidth: 1))
			.opacity(configuration.isPressed ? 0.7 : 1)
			.animation(.easeOut(duration: 0.12), value: configuration.isPressed)
	}
}

// MARK: - Pill
struct ODPill: View {
	let text: String
	let color: Color
	var icon: String? = nil

	var body: some View {
		HStack(spacing: 4) {
			if let icon {
				Image(systemName: icon)
					.font(.caption2.weight(.bold))
			}
			Text(text)
				.font(.system(.caption, design: .rounded).weight(.semibold))
				.lineLimit(1)
		}
		.foregroundStyle(color)
		.padding(.horizontal, 9)
		.padding(.vertical, 4)
		.background(Capsule().fill(color.opacity(0.15)))
	}
}

/// Green while there's time left, red when close to or past expiry.
struct ODExpiryPill: View {
	let expiration: Date?
	var revoked: Bool = false

	@AppStorage("Odysseus.expiryWarningDays") private var _warningDays: Int = 3

	var body: some View {
		if revoked {
			ODPill(text: .localized("Revoked"), color: ODTheme.revoked, icon: "xmark.octagon.fill")
		} else if let expiration {
			let info = expiration.expirationInfo()
			let left = expiration.timeIntervalSinceNow
			let isWarning = left < Double(_warningDays) * 86_400
			ODPill(
				text: left <= 0 ? .localized("Expired") : info.formatted,
				color: isWarning ? ODTheme.revoked : ODTheme.valid,
				icon: left <= 0 ? "xmark.octagon.fill" : "clock.fill"
			)
		}
	}
}

// MARK: - Section header
struct ODSectionHeader: View {
	let title: String
	var subtitle: String? = nil
	var actionTitle: String? = nil
	var action: (() -> Void)? = nil

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.system(.title3, design: .rounded).weight(.bold))
					.foregroundStyle(.white)
				if let subtitle {
					Text(subtitle)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			if let actionTitle, let action {
				Button(actionTitle, action: action)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(Color.accentColor)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - Empty state
struct ODEmptyStateView: View {
	let systemImage: String
	let title: String
	let message: String
	var actionTitle: String? = nil
	var action: (() -> Void)? = nil

	var body: some View {
		VStack(spacing: 14) {
			Image(systemName: systemImage)
				.font(.system(size: 46, weight: .medium))
				.foregroundStyle(Color.accentColor.opacity(0.85))

			VStack(spacing: 6) {
				Text(title)
					.font(.system(.title3, design: .rounded).weight(.bold))
				Text(message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}

			if let actionTitle, let action {
				Button(actionTitle, action: action)
					.buttonStyle(ODCapsuleButtonStyle(filled: true))
					.padding(.top, 4)
			}
		}
		.padding(.horizontal, 40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

// MARK: - Logo
struct ODLogoView: View {
	var size: CGFloat = 64

	var body: some View {
		Image("Logo")
			.resizable()
			.scaledToFit()
			.frame(width: size, height: size)
			.clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
					.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
			)
	}
}
