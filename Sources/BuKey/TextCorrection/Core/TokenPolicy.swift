import Foundation

enum TokenPolicy {
    static func isEligibleForAutomaticCorrection(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        guard !token.contains(where: { $0.isNumber }) else { return false }
        guard !token.contains(where: { "@_/\\{}()".contains($0) }) else { return false }
        guard !hasURISchemePrefix(token) else { return false }

        let characters = Array(token)
        for index in characters.indices.dropLast() {
            let next = characters[characters.index(after: index)]
            if characters[index] == ".", index > characters.startIndex {
                let previous = characters[characters.index(before: index)]
                if isAlphaNumeric(previous) && isAlphaNumeric(next) { return false }
            }
        }

        return characters.filter(LayoutConverter.isSupportedLetter).count >= 3
    }

    private static func isAlphaNumeric(_ character: Character) -> Bool {
        character.isNumber || LayoutConverter.isSupportedLetter(character)
    }

    private static func hasURISchemePrefix(_ token: String) -> Bool {
        let scalars = Array(token.unicodeScalars)
        guard let first = scalars.first, isASCIILetter(first) else { return false }
        for scalar in scalars.dropFirst() {
            if scalar == ":" { return true }
            guard isASCIILetter(scalar) || scalar.value.isASCIIASCIIDigit || scalar == "+" || scalar == "-" || scalar == "." else { return false }
        }
        return false
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

private extension UInt32 {
    var isASCIIASCIIDigit: Bool { (48...57).contains(self) }
}
