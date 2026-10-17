import Foundation

/// Reads `KEY=value` lines the way the KonaClaw env file is written. Values are taken whole:
/// a `#` inside a value is part of the value, not a comment. The last assignment wins.
public enum EnvFile {
    public static func value(named name: String, in text: String) -> String? {
        var found: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            found = value
        }
        return found
    }
}
