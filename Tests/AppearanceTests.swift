import SwiftUI
import Foundation

@main struct AppearanceTests {
    static func main() {
        precondition(PFGlassPolicy.style(enabled: true, reduceTransparency: false, modernOS: true) == .liquid)
        precondition(PFGlassPolicy.style(enabled: true, reduceTransparency: false, modernOS: false) == .material)
        for modern in [false, true] {
            precondition(PFGlassPolicy.style(enabled: false, reduceTransparency: false, modernOS: modern) == .opaque)
            precondition(PFGlassPolicy.style(enabled: true, reduceTransparency: true, modernOS: modern) == .opaque)
            precondition(PFGlassPolicy.style(enabled: false, reduceTransparency: true, modernOS: modern) == .opaque)
        }
        let suite = "PonteFotos.appearance.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let theme = AppStorage(wrappedValue: "system", PFAppearance.themeKey, store: defaults)
        let glass = AppStorage(wrappedValue: true, PFAppearance.glassKey, store: defaults)
        precondition(theme.wrappedValue == "system" && glass.wrappedValue)
        theme.wrappedValue = "dark"; glass.wrappedValue = false
        let restored = AppStorage(wrappedValue: "system", PFAppearance.themeKey, store: defaults)
        let restoredGlass = AppStorage(wrappedValue: true, PFAppearance.glassKey, store: defaults)
        precondition(restored.wrappedValue == "dark" && !restoredGlass.wrappedValue)
        theme.wrappedValue = "system"
        precondition(PFColorTheme(rawValue: theme.wrappedValue)?.colorScheme == nil)
        precondition(PFColorTheme(rawValue: "unknown") == nil)
        print("Appearance: transparency/accessibility compatibility matrix and isolated preference persistence passed.")
    }
}
