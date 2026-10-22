import SwiftUI
import Foundation
import AppKit

@main struct AppearanceTests {
    @MainActor static func main() {
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
        verifyApplicationAppearanceInheritance()
        print("Appearance: transparency/accessibility matrix, isolated preferences, and live application/window/sheet inheritance passed.")
    }

    @MainActor private static func verifyApplicationAppearanceInheritance() {
        // Only this test process is changed; no system appearance or user app defaults are written.
        let application = NSApplication.shared
        application.finishLaunching()
        let original = application.appearance
        defer { application.appearance = original }
        application.appearance = nil
        let inherited = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSPanel(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        for theme in [PFColorTheme.dark, .light, .dark] {
            PFAppearanceController.apply(theme, to: application)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            let expected: NSAppearance.Name = theme == .dark ? .darkAqua : .aqua
            precondition(application.appearance?.name == expected)
            precondition(window.appearance == nil && sheet.appearance == nil)
            precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            precondition(sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)

            PFAppearanceController.apply(.system, to: application)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            precondition(application.appearance == nil, "System must remove the forced appearance")
            precondition(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == inherited)
            precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == inherited)
            precondition(sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == inherited)
        }
    }
}
