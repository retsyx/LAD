import Foundation

/// User names are filenames, not generated design summaries. Preserve their
/// punctuation and spacing, while keeping every project visible and portable.
enum ProjectNaming {
    static func userName(_ entered: String) throws -> String {
        var name = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        if name.lowercased().hasSuffix(".lad") {
            name.removeLast(4)
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try validateBase(name)
        return name
    }

    static func validateSavedName(_ name: String) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard normalized.utf8.elementsEqual(name.utf8) else {
            throw invalid("The saved design name is not a valid filename.")
        }
        try validateBase(name)
    }

    private static func validateBase(_ name: String) throws {
        guard !name.isEmpty else { throw invalid("Enter a design name.") }
        guard !name.hasPrefix(".") else { throw invalid("Design names cannot begin with a period.") }
        guard !name.contains("/"), !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid("Design names cannot contain a slash, colon, or control character.")
        }
        // Leave room for the .lad extension and an automatic collision suffix.
        guard name.utf8.count <= 220 else { throw invalid("The design name is too long.") }
    }

    private static func invalid(_ message: String) -> LADError { .message(message) }
}
