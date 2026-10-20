import Carbon
import Foundation

enum KeyboardLayout: Equatable, Sendable {
    case english
    case russian
}

@MainActor
protocol KeyboardLayoutSwitching: AnyObject {
    @discardableResult
    func select(_ layout: KeyboardLayout) -> Bool
}

@MainActor
final class SystemKeyboardLayoutSwitcher: KeyboardLayoutSwitching {
    func select(_ layout: KeyboardLayout) -> Bool {
        let languagePrefix = layout == .english ? "en" : "ru"
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else { return false }
        let sources = unmanaged.takeRetainedValue() as NSArray

        for case let source as TISInputSource in sources {
            guard boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { continue }
            let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
            guard languages.contains(where: { $0.lowercased().hasPrefix(languagePrefix) }) else { continue }
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    private func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        (property(source, key) as? NSNumber)?.boolValue ?? false
    }
}

enum LayoutConverter {
    private static let englishLower = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./")
    private static let russianLower = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.")
    private static let englishUpper = Array("~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
    private static let russianUpper = Array("ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")

    private static let englishToRussian = dictionary(from: englishLower + englishUpper, to: russianLower + russianUpper)
    private static let russianToEnglish = dictionary(from: russianLower + russianUpper, to: englishLower + englishUpper)
    private static let englishLetters = Set(Array("qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM"))
    private static let russianLetters = Set(Array("ёйцукенгшщзхъфывапролджэячсмитьбюЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ"))

    static func convert(_ text: String, to target: KeyboardLayout) -> String {
        let mapping = target == .russian ? englishToRussian : russianToEnglish
        return String(text.map { mapping[$0] ?? $0 })
    }

    static func convertToOppositeLayout(_ text: String) -> String {
        guard let source = dominantLayout(in: text) else { return text }
        return convert(text, to: source == .english ? .russian : .english)
    }

    static func isSupportedLetter(_ character: Character) -> Bool {
        englishLetters.contains(character) || russianLetters.contains(character)
    }

    static func dominantLayout(in text: String) -> KeyboardLayout? {
        let englishCount = text.reduce(into: 0) { count, character in
            if englishLetters.contains(character) { count += 1 }
        }
        let russianCount = text.reduce(into: 0) { count, character in
            if russianLetters.contains(character) { count += 1 }
        }
        guard englishCount != russianCount else { return nil }
        return englishCount > russianCount ? .english : .russian
    }

    private static func dictionary(from source: [Character], to destination: [Character]) -> [Character: Character] {
        Dictionary(uniqueKeysWithValues: zip(source, destination))
    }
}
