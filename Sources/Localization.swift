import Foundation

/// Stable preference identifiers; changing language takes effect on the next launch.
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

struct PFLocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"; arguments.append(String(describing: value))
        }
    }
}

enum PFLocalization {
    static let preferenceKey = "PonteFotos.language"
    static let currentLanguage: PFAppLanguage = {
        if let override = ProcessInfo.processInfo.environment["PONTEFOTOS_LANGUAGE"],
           let language = PFAppLanguage(rawValue: override) { return language }
        return PFAppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }()
    static let languageCode: String = {
        switch currentLanguage {
        case .english: return "en"
        case .portuguese: return "pt-BR"
        case .system:
            return Bundle.preferredLocalizations(from: ["en", "pt-BR"], forPreferences: Locale.preferredLanguages).first ?? "en"
        }
    }()
    static let locale = Locale(identifier: languageCode == "pt-BR" ? "pt_BR" : "en_US")
    static let bundle: Bundle = {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }()
    static func savePreference(_ language: PFAppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
        if language == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages") }
    }
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
            return substitute(text.key, arguments: text.arguments)
        }
        return substitute(translated, arguments: text.arguments)
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
