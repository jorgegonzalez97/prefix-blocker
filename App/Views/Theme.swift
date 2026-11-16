import SwiftUI
import UIKit

/// Colours and small building blocks shared by every screen.
enum Theme {
    // Text and icon colours, legible on the system backgrounds in light and dark.
    static let green = adaptive(light: (0.05, 0.50, 0.30), dark: (0.30, 0.85, 0.50))
    static let orange = adaptive(light: (0.76, 0.35, 0.00), dark: (1.00, 0.66, 0.24))
    static let blue = adaptive(light: (0.20, 0.34, 0.90), dark: (0.56, 0.67, 1.00))
    static let red = adaptive(light: (0.80, 0.16, 0.18), dark: (1.00, 0.47, 0.44))

    // Solid fills that carry white text or stand alone as a status mark.
    static let greenFill = Color(red: 0.12, green: 0.62, blue: 0.38)
    static let orangeFill = Color(red: 0.86, green: 0.44, blue: 0.06)
    static let blueFill = Color(red: 0.29, green: 0.40, blue: 0.95)
    static let redFill = Color(red: 0.84, green: 0.24, blue: 0.25)

    /// The indigo of the app icon and accent colour.
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.47, blue: 0.99), Color(red: 0.22, green: 0.28, blue: 0.80)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// The mood of the status card at the top of the main screen.
enum HeroKind {
    case protected, attention, working, failed, neutral

    /// Top and bottom of the card's gradient; dark enough for white text.
    var colors: [Color] {
        switch self {
        case .protected: return [Color(red: 0.07, green: 0.56, blue: 0.38), Color(red: 0.02, green: 0.39, blue: 0.34)]
        case .attention: return [Color(red: 0.85, green: 0.42, blue: 0.06), Color(red: 0.70, green: 0.27, blue: 0.05)]
        case .working: return [Color(red: 0.29, green: 0.40, blue: 0.95), Color(red: 0.19, green: 0.25, blue: 0.76)]
        case .failed: return [Color(red: 0.82, green: 0.22, blue: 0.23), Color(red: 0.60, green: 0.11, blue: 0.16)]
        case .neutral: return [Color(red: 0.17, green: 0.23, blue: 0.44), Color(red: 0.08, green: 0.10, blue: 0.23)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var tint: Color { colors[0] }
}

/// Grouped background with a soft glow of the current status colour at the top.
struct ScreenBackground: View {
    let tint: Color

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 380)
        }
        .ignoresSafeArea()
        .animation(.smooth, value: tint)
    }
}

/// The three digits of a prefix on a rounded tile.
struct DigitsBadge: View {
    let digits: String
    var dimmed = false
    var size: CGFloat = 60

    var body: some View {
        Text(digits)
            .font(.system(size: size * 0.37, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(dimmed ? AnyShapeStyle(Color(.systemGray2)) : AnyShapeStyle(Theme.brandGradient),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// One thin mark per extension of a prefix, coloured by its state.
struct SwitchSegments: View {
    let states: [SlotState]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                Capsule().fill(state.fill).frame(height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A numbered cell for one extension, as it is named in Settings.
struct SwitchCell: View {
    let slot: Int
    let state: SlotState

    var body: some View {
        Text(AppConstants.slotLabel(slot))
            .font(.caption.monospacedDigit().weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(state == .unused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .background(state.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Switch \(AppConstants.slotLabel(slot)), \(state.name)")
    }
}

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 11, height: 11)
            Text(text)
        }
    }
}

extension SlotState {
    var name: String {
        switch self {
        case .unused: return "not in use"
        case .waiting: return "waiting"
        case .loading: return "loading"
        case .loaded: return "on"
        case .needsSwitch: return "turn on in Settings"
        case .failed: return "failed"
        }
    }

    var fill: Color {
        switch self {
        case .unused: return Color(.systemFill)
        case .waiting, .loading: return Theme.blueFill
        case .loaded: return Theme.greenFill
        case .needsSwitch: return Theme.orangeFill
        case .failed: return Theme.redFill
        }
    }
}

extension PrefixStatus {
    /// Short label, symbol and colour for the pill on a prefix.
    func pill(isSyncing: Bool) -> (text: String, systemImage: String, color: Color) {
        switch self {
        case .active:
            return ("Active", "checkmark.circle.fill", Theme.green)
        case .paused:
            return ("Paused", "pause.circle.fill", Color(.secondaryLabel))
        case .needsSwitches(let slots):
            return ("Turn on \(slots.count)", "switch.2", Theme.orange)
        case .loading(let done, let total):
            return (isSyncing ? "Loading \(done)/\(total)" : "Waiting", "arrow.triangle.2.circlepath", Theme.blue)
        case .failed:
            return ("Failed", "exclamationmark.triangle.fill", Theme.red)
        }
    }

    var spokenDescription: String {
        switch self {
        case .active: return "active"
        case .paused: return "paused"
        case .needsSwitches(let slots): return "\(slots.count) switches to turn on in Settings"
        case .loading(let done, let total): return "\(done) of \(total) switches loaded"
        case .failed(let message): return "failed. \(message)"
        }
    }
}

extension AreaCode: Identifiable {
    var id: String { digits }

    /// "Toll-free", "Texas", or a generic name for codes without a known region.
    var regionName: String { AreaCodeDirectory.region(for: self) ?? "Area code \(digits)" }
}

enum SettingsPath {
    static let text = "Settings › Apps › Phone › Call Blocking & Identification"
}

extension BlockerModel {
    /// Starts a sync without waiting for it; what every screen does after an edit.
    func syncSoon() {
        Task { await AppEnvironment.sync(self) }
    }
}
