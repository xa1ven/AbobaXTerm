import Foundation
import Observation

/// Interface languages the app ships with.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case russian = "ru"

    public var id: String { rawValue }

    /// Name of the language in that language (never translated).
    public var nativeName: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }
}

/// The current interface language.
///
/// Strings are looked up with `L("English text")`: the English text is the key,
/// and `Russian.swift` holds the translations. Reading the language inside a
/// SwiftUI `body` registers an observation, so views redraw when it changes.
@Observable
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()
    public static let defaultsKey = "appLanguage"

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var stored: AppLanguage

    private init() {
        stored = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .english
    }

    public var language: AppLanguage {
        get {
            access(keyPath: \.language)
            return lock.withLock { stored }
        }
        set {
            guard newValue != language else { return }
            withMutation(keyPath: \.language) {
                lock.withLock { stored = newValue }
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultsKey)
            applyToSystem()
        }
    }

    /// Switches the language for this run only, without saving it (debug snapshots).
    public func overrideForThisRun(_ language: AppLanguage) {
        withMutation(keyPath: \.language) {
            lock.withLock { stored = language }
        }
    }

    /// Makes the parts AppKit translates itself (standard menu items, open and
    /// save panels) follow the app language instead of the system one. Read by
    /// the system at launch, so call it before anything else in the app.
    public func applyToSystem() {
        let wanted = [lock.withLock { stored }.rawValue]
        if UserDefaults.standard.stringArray(forKey: "AppleLanguages") != wanted {
            UserDefaults.standard.set(wanted, forKey: "AppleLanguages")
        }
    }

    func translate(_ key: String, in language: AppLanguage) -> String {
        switch language {
        case .english: key
        case .russian: Russian.strings[key] ?? key
        }
    }
}

/// Localized text for an English key. `%@` placeholders are filled with
/// `arguments` in order; `%1$@`, `%2$@`… pick an argument by position.
public func L(_ key: String, _ arguments: Any...) -> String {
    let text = L10n.shared.translate(key, in: L10n.shared.language)
    return arguments.isEmpty ? text : L10nFormat.fill(text, arguments.map { String(describing: $0) })
}

/// Localized "count + noun" phrase. `one` and `other` are the English forms
/// with a `%@` for the number; Russian forms are looked up by `other`.
public func LN(_ count: Int, _ one: String, _ other: String) -> String {
    let template: String
    switch L10n.shared.language {
    case .english:
        template = count == 1 ? one : other
    case .russian:
        guard let forms = Russian.plurals[other] else {
            template = count == 1 ? one : other
            break
        }
        template = forms[L10nFormat.russianPluralIndex(count)]
    }
    return L10nFormat.fill(template, [String(count)])
}

public enum L10nFormat {
    static func fill(_ template: String, _ arguments: [String]) -> String {
        var result = ""
        var next = 0
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            result += rest[..<percent]
            let tail = rest[rest.index(after: percent)...]
            if tail.hasPrefix("@") {
                result += next < arguments.count ? arguments[next] : ""
                next += 1
                rest = tail.dropFirst()
            } else if let digit = tail.first?.wholeNumberValue, tail.dropFirst().hasPrefix("$@") {
                result += (1...arguments.count).contains(digit) ? arguments[digit - 1] : ""
                rest = tail.dropFirst(3)
            } else {
                result += "%"
                rest = tail
            }
        }
        return result + rest
    }

    /// 0: one (1, 21, 31…), 1: few (2–4, 22–24…), 2: many (0, 5–20, 25–30…).
    public static func russianPluralIndex(_ count: Int) -> Int {
        let n = abs(count) % 100
        if (11...14).contains(n) { return 2 }
        switch n % 10 {
        case 1: return 0
        case 2...4: return 1
        default: return 2
        }
    }
}
