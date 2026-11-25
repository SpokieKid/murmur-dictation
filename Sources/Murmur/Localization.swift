import Foundation

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("MurmurHotkeyChanged")
    static let appLanguageChanged = Notification.Name("MurmurAppLanguageChanged")
}

enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

/// Runtime-selectable localization for both SwiftUI and AppKit surfaces.
///
/// macOS normally chooses one localization only when an app launches. Murmur
/// also offers an in-app language picker, so lookups are routed through the
/// explicitly selected `.lproj` bundle and can refresh without a relaunch.
enum L10n {
    static var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: Defaults.appLanguage) ?? .system
    }

    static var resolvedLanguageCode: String {
        switch selectedLanguage {
        case .english:
            return AppLanguage.english.rawValue
        case .simplifiedChinese:
            return AppLanguage.simplifiedChinese.rawValue
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh")
                ? AppLanguage.simplifiedChinese.rawValue
                : AppLanguage.english.rawValue
        }
    }

    static func tr(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: tr(key),
            locale: Locale(identifier: resolvedLanguageCode),
            arguments: arguments
        )
    }

    private static var localizedBundle: Bundle {
        let resources = Bundle.murmurResources
        // SwiftPM normalizes localization directory names to lowercase (for
        // example `zh-Hans.lproj` becomes `zh-hans.lproj`) on case-sensitive
        // build volumes, so resolve both spellings explicitly.
        for code in [resolvedLanguageCode, resolvedLanguageCode.lowercased()] {
            if let url = resources.url(forResource: code, withExtension: "lproj"),
               let bundle = Bundle(url: url) { return bundle }
        }
        return resources
    }
}

extension Bundle {
    /// In an assembled `.app` the SwiftPM resource bundle lives under
    /// `Contents/Resources`. During `swift run` and tests, `Bundle.module`
    /// points at the build-tree copy instead.
    static var murmurResources: Bundle {
        if let resourcesURL = Bundle.main.resourceURL,
           let bundled = Bundle(
               url: resourcesURL.appendingPathComponent("Murmur_Murmur.bundle")
           ) {
            return bundled
        }
        return Bundle.module
    }
}
