import Foundation

enum GEMSIDNormalizer {
    static let canonicalLength = 7
    private static let legacyNumericLengths: Set<Int> = [canonicalLength - 1]

    static func normalize(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard legacyNumericLengths.contains(trimmed.count),
              containsOnlyASCIIDigits(trimmed)
        else {
            return trimmed
        }
        return String(repeating: "0", count: canonicalLength - trimmed.count) + trimmed
    }

    private static func containsOnlyASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= CharacterByte.zero && byte <= CharacterByte.nine
        }
    }

    private enum CharacterByte {
        static let zero: UInt8 = 48
        static let nine: UInt8 = 57
    }
}
