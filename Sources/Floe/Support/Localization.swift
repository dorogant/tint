import Foundation

/// UI text uses the selected language; catalogue metadata and lyrics stay original.
enum L10n {
    static var language: String {
        let selected = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if selected == "en" || selected == "uk" { return selected }
        return Bundle.preferredLocalizations(from: ["en", "uk"]).first ?? "en"
    }
    static var locale: Locale { Locale(identifier: language) }
    static var bundle: Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
