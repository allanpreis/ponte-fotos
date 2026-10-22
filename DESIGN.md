# Design

## Source of truth
Active · 2026-10-22 · Ponte Fotos macOS, main window, metadata review and all Immich management sheets. Evidence: current SwiftUI views, README, original user screenshots and existing synthetic visual fixture. This contract governs the 0.7 settings and appearance update.

## Brand
Calm, precise and familiar to macOS. Photography remains the subject; interface decoration is restrained. Preserve the existing app logo. Avoid gradients, neon, marketing slogans and web-style dashboards.

## Product goals
Make source, destination, connection and pending work easy to recognize. Give primary actions a clear location. Preserve original files and all existing confirmation guards. No change to upload, duplicate analysis, networking, credentials or transaction rules.

## Personas and jobs
A Mac user importing original photos or reviewing an Immich library, sometimes offline or with a server under maintenance. Common jobs: choose source, review metadata, select destination, send; inspect duplicates and confirm organization.

## Information architecture
Main window: source sidebar, compact connection-status button, source/destination sections, selectable media list and persistent actions. No scrolling connection pane in the main workflow. Dedicated Settings page (sidebar or Cmd+,) owns Connection, Accounts/API and Appearance sections; only its long forms scroll. Immich management retains five named areas. Metadata review has summary, capture date, location and persistent save/cancel actions.

## Design principles
Use native controls before custom equivalents. Separate configuration from everyday actions. Make read, selection and mutation states distinct. A label must explain a state without relying only on color. Safety text must remain visible and accurate.

## Visual language
System SF typography; no bundled fonts. Page title 28pt semibold, section headings native headline, body 13pt, secondary 11–12pt. Native blue accent, semantic primary/secondary text, window and control backgrounds that adapt to light/dark. Green for confirmed results, orange for warnings, red for errors. Spacing 4/8/12/16/20/24/32pt; cards 18pt continuous radius, subtle 0.5pt separator stroke. Native Liquid Glass only in sidebar/footer on macOS26+, regularMaterial fallback on macOS14/15. Content cards remain opaque. User may disable glass; Reduce Transparency always forces opaque navigation. No decorative animation; honor system reduced motion.

## Components
`Sources/DesignSystem.swift` owns PFTheme, PFCard, PFSectionHeading, PFBadge and PFEmptyState. Cards group related tasks rather than individual labels. Use borderedProminent only for primary actions. Live/static badges occupy their own layout row, never overlay filenames or dates. Selected keeper needs text/icon as well as border color.

## Accessibility
Native button/picker/toggle semantics, VoiceOver labels and keyboard focus. Decorative icons hidden from accessibility. Semantic colors preserve system adaptation; text never reduced to faint custom gray. Long filenames may wrap or truncate with selectable full metadata in review. No information communicated solely through color; disabled controls retain explanatory context.

## Responsive behavior
Desktop target macOS 14+, Apple Silicon. Main window minimum 900×650, default about 1220×840. Sidebar about 220pt. Source/destination and action groups use ViewThatFits or adaptive grids; stack when horizontal content cannot fit. Settings forms scroll on their dedicated page, not above the library. Review content scrolls with actions pinned. Check compact and large windows, plus light and dark appearances. No mobile web interface is introduced.

## Interaction states
Empty library has a clear source prompt. Connection state remains visible when collapsed. Loading shows progress and existing cancel/pause semantics. Offline server disables remote actions, local review/export stay available. Errors are selectable and labeled. Mutation review keeps explicit acceptance and all existing protection rules.

## Content voice
Portuguese, concise verbs: Abrir biblioteca, Escolher pasta, Revisar, Enviar. Explain what will change before confirmation. Preserve precise Live Photo/static distinctions. Do not expose internal implementation terms unless useful for an informed decision.

## Implementation constraints
SwiftUI/AppKit only, existing macOS 14 APIs, no dependencies. Preserve observable model identity and selection state. Views may be extracted, engines and persistence remain unchanged. Run existing connection/management/media tests, build/plist/signature, plus synthetic native visual checks. Verify no private configuration is introduced into source.

## Open questions
No blocking questions. User explicitly requested and received persisted System/Light/Dark themes and a transparency/glass toggle, propagated to each presentation root. A signed/notarized distribution and Intel support are outside this visual refresh.


## Apple API references
- [Materials — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))
- [accessibilityReduceTransparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency)

SDK27 interfaces inspected: glassEffect(_:in:) requires macOS26; deployment remains macOS14 using runtime availability guards. No custom shaders, compatibility packages or accessibility setting overrides.
