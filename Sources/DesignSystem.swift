import SwiftUI
import AppKit

/// Shared native appearance. Semantic AppKit colors follow light/dark and contrast settings.
enum PFTheme {
    static let accent: Color = .blue
    static let background = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor).opacity(0.35)
    static let corner: CGFloat = 18
}


/// Fixed sRGB fills keep the primary action legible when macOS applies Liquid Glass
/// or the user's accent color. The opaque surface is deliberate in both appearances.
enum PFPrimaryButtonPalette {
    struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red; self.green = green; self.blue = blue
        }
        var color: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1) }
    }
    static func fill(dark: Bool, enabled: Bool, pressed: Bool, hovered: Bool) -> RGB {
        if !enabled { return dark ? RGB(48, 58, 70) : RGB(223, 228, 234) }
        if pressed { return dark ? RGB(28, 60, 99) : RGB(16, 63, 115) }
        if hovered { return dark ? RGB(44, 94, 151) : RGB(18, 79, 144) }
        return dark ? RGB(37, 79, 128) : RGB(23, 94, 168)
    }
    static func foreground(dark: Bool, enabled: Bool) -> RGB {
        if enabled { return RGB(255, 255, 255) }
        return dark ? RGB(166, 176, 187) : RGB(89, 100, 114)
    }
}

struct PFPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PFPrimaryButtonBody(configuration: configuration)
    }
}

@MainActor private final class PFPrimaryButtonState: ObservableObject {
    @Published var hovered = false
}

private struct PFPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlSize) private var controlSize
    @StateObject private var state = PFPrimaryButtonState()

    private var dark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }
    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(PFPrimaryButtonPalette.foreground(dark: dark, enabled: isEnabled).color)
            .padding(.horizontal, controlSize == .large ? 18 : 14)
            .padding(.vertical, controlSize == .large ? 10 : 8)
            .frame(minHeight: controlSize == .large ? 38 : 34)
            .background(PFPrimaryButtonPalette.fill(dark: dark, enabled: isEnabled, pressed: configuration.isPressed, hovered: state.hovered).color, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.16 : 0.08), lineWidth: contrast == .increased ? 1.5 : 0.5))
            .overlay {
                if isFocused && isEnabled {
                    shape.inset(by: -3).strokeBorder(dark ? Color.white : Color(nsColor: .labelColor), lineWidth: 2)
                }
            }
            .contentShape(shape)
            .onHover { state.hovered = $0 }
    }
}

struct PFCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(PFTheme.surface, in: RoundedRectangle(cornerRadius: PFTheme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PFTheme.corner, style: .continuous).strokeBorder(PFTheme.separator, lineWidth: 0.5))
    }
}

struct PFSectionHeading: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(PFTheme.accent).frame(width: 34, height: 34)
                    .background(PFTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

struct PFBadge: View {
    let title: String
    var systemImage: String?
    var color: Color
    init(_ title: String, systemImage: String? = nil, color: Color = PFTheme.accent) {
        self.title = title; self.systemImage = systemImage; self.color = color
    }
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title)
        }.font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PFEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String
    init(_ title: String, detail: String, systemImage: String) { self.title = title; self.detail = detail; self.systemImage = systemImage }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 25, weight: .light)).foregroundStyle(PFTheme.accent)
                .frame(width: 48, height: 48).background(PFTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(18).frame(maxWidth: .infinity, minHeight: 160)
    }
}

// Non-sensitive, per-app preferences. Connection data remains in the Keychain.
enum PFAppearance {
    static let themeKey = "PonteFotos.appearance.theme"
    static let glassKey = "PonteFotos.appearance.glass"
}
enum PFColorTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return L("Sistema"); case .light: return L("Claro"); case .dark: return L("Escuro") } }
    var symbol: String { switch self { case .system: return "desktopcomputer"; case .light: return "sun.max"; case .dark: return "moon" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

/// Use AppKit's application-wide inheritance rather than a SwiftUI window preference.
/// Clearing the override also lets existing windows and sheets follow later system changes.
@MainActor enum PFAppearanceController {
    static func apply(_ theme: PFColorTheme) {
        apply(theme, to: .shared)
    }

    static func apply(_ theme: PFColorTheme, to application: NSApplication) {
        switch theme {
        case .system: application.appearance = nil
        case .light: application.appearance = NSAppearance(named: .aqua)
        case .dark: application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
enum PFGlassStyle: Equatable { case opaque, material, liquid }
enum PFGlassPolicy {
    static func style(enabled: Bool, reduceTransparency: Bool, modernOS: Bool) -> PFGlassStyle {
        if !enabled || reduceTransparency { return .opaque }
        return modernOS ? .liquid : .material
    }
}
private struct PFGlassEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var pfGlassEnabled: Bool {
        get { self[PFGlassEnabledKey.self] }
        set { self[PFGlassEnabledKey.self] = newValue }
    }
}
struct PFNavigationSurface: ViewModifier {
    @Environment(\.pfGlassEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let modern: Bool = { if #available(macOS 26.0, *) { return true }; return false }()
        switch PFGlassPolicy.style(enabled: enabled, reduceTransparency: reduceTransparency, modernOS: modern) {
        case .opaque: content.background(PFTheme.surface)
        case .material: content.background(.regularMaterial)
        case .liquid:
            if #available(macOS 26.0, *) { content.glassEffect(.regular, in: Rectangle()) }
            else { content.background(.regularMaterial) }
        }
    }
}
