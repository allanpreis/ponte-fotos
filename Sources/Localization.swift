import Foundation
import Combine

/// Stable identifiers used only for the language preference.
enum PFAppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", portuguese = "pt-BR"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("Sistema")
        case .english: return "English"
        case .portuguese: return "Português (Brasil)"
        }
    }
}

struct PFLocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Equatable, Codable {
    let key: String
    let arguments: [PFMessage]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [PFMessage] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"; arguments.append((value as? PFMessage) ?? .verbatim(String(describing: value)))
        }
    }
}

enum PFLocalization {
    static let preferenceKey = "PonteFotos.language"
    static let shared = PFLocalizationState()
    static let didChangeNotification = Notification.Name("PonteFotos.languageDidChange")
    static var currentLanguage: PFAppLanguage { shared.language }
    static var languageCode: String { shared.languageCode }
    static var locale: Locale { shared.locale }
    static var bundle: Bundle { shared.bundle }
    static func savePreference(_ language: PFAppLanguage) { shared.setLanguage(language) }
    static func formatDate(_ value: Date, date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        value.formatted(Date.FormatStyle(date: date, time: time, locale: locale))
    }
    static func render(_ text: PFLocalizedText, bundle: Bundle = bundle, locale: Locale = locale) -> String {
        let translated = bundle.localizedString(forKey: text.key, value: text.key, table: nil)
        guard !text.arguments.isEmpty else { return translated }
        // Substitute only our own placeholders. Literal percent signs and user values
        // never become printf directives, and arguments containing %@ remain untouched.
        let parts = translated.components(separatedBy: "%@")
        guard parts.count == text.arguments.count + 1 else {
            return substitute(text.key, arguments: text.arguments.map(\.text))
        }
        return substitute(translated, arguments: text.arguments.map(\.text))
    }
    private static func substitute(_ template: String, arguments: [String]) -> String {
        let parts = template.components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return template }
        return parts.enumerated().map { index, part in
            index < arguments.count ? part + arguments[index] : part
        }.joined()
    }
}

func L(_ text: PFLocalizedText) -> String { PFLocalization.render(text) }
func LV(_ value: String) -> String {
    PFLocalization.bundle.localizedString(forKey: value, value: value, table: nil)
}


/// A message retains its source and opaque arguments, so a language change never
/// needs to match translated output or reinterpret a filename supplied by a user.
struct PFMessage: Equatable, Codable, CustomStringConvertible, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    private let source: PFLocalizedText
    private let isVerbatim: Bool
    init(_ source: PFLocalizedText) { self.source = source; isVerbatim = false }
    init(stringLiteral value: String) { self.init(PFLocalizedText(stringLiteral: value)) }
    init(stringInterpolation: PFLocalizedText.StringInterpolation) { self.init(PFLocalizedText(stringInterpolation: stringInterpolation)) }
    private init(verbatim value: String) { source = PFLocalizedText(stringLiteral: value); isVerbatim = true }
    static func verbatim(_ value: String) -> Self { Self(verbatim: value) }
    static func error(_ error: Error) -> Self {
        (error as? PFMessageProviding)?.pfMessage ?? .verbatim(error.localizedDescription)
    }
    static func joined(_ messages: [Self], separator: String = "") -> Self {
        guard !messages.isEmpty else { return .verbatim("") }
        var interpolation = PFLocalizedText.StringInterpolation(literalCapacity: 0, interpolationCount: messages.count)
        for (index, message) in messages.enumerated() {
            if index > 0 { interpolation.appendLiteral(separator) }
            interpolation.appendInterpolation(message)
        }
        return Self(PFLocalizedText(stringInterpolation: interpolation))
    }
    var text: String { isVerbatim ? source.key : PFLocalization.render(source) }
    var description: String { text }
    var isEmpty: Bool { text.isEmpty }
    func contains(_ value: String) -> Bool { text.contains(value) }
    static func + (lhs: Self, rhs: Self) -> Self { .joined([lhs, rhs]) }
}
func M(_ text: PFLocalizedText) -> PFMessage { PFMessage(text) }
protocol PFMessageProviding { var pfMessage: PFMessage { get } }

final class PFLocalizationState: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let lock = NSLock()
    private var selected: PFAppLanguage
    private let defaults: UserDefaults
    private let resources: Bundle
    private let preferredLanguages: () -> [String]
    init(defaults: UserDefaults = .standard, resources: Bundle = .main, preferredLanguages: @escaping () -> [String] = {
        // Read the system domain rather than a previous app-specific AppleLanguages
        // override, which Foundation can cache for the life of this process.
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
    }) {
        self.defaults = defaults; self.resources = resources; self.preferredLanguages = preferredLanguages
        selected = PFAppLanguage(rawValue: defaults.string(forKey: PFLocalization.preferenceKey) ?? "system") ?? .system
    }
    var language: PFAppLanguage { lock.lock(); defer { lock.unlock() }; return selected }
    var languageCode: String {
        switch language {
        case .english: return "en"
        case .portuguese: return "pt-BR"
        case .system: return Bundle.preferredLocalizations(from: ["en", "pt-BR"], forPreferences: preferredLanguages()).first ?? "en"
        }
    }
    var locale: Locale {
        let code = languageCode
        // Preserve the user's regional format when the region speaks the selected
        // language (for example British dates on a Mac configured for the UK).
        let region = Locale.autoupdatingCurrent
        if region.language.languageCode?.identifier == (code == "pt-BR" ? "pt" : "en") { return region }
        return Locale(identifier: code == "pt-BR" ? "pt_BR" : "en_US")
    }
    var bundle: Bundle {
        guard let path = resources.path(forResource: languageCode, ofType: "lproj"), let result = Bundle(path: path) else { return resources }
        return result
    }
    func setLanguage(_ value: PFAppLanguage) {
        precondition(Thread.isMainThread, "Language selection must run on the UI thread")
        objectWillChange.send()
        lock.lock(); selected = value; lock.unlock()
        defaults.set(value.rawValue, forKey: PFLocalization.preferenceKey)
        if value == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([value.rawValue], forKey: "AppleLanguages") }
        NotificationCenter.default.post(name: PFLocalization.didChangeNotification, object: self)
    }
}

func MV(_ key: String) -> PFMessage { PFMessage(PFLocalizedText(stringLiteral: key)) }
