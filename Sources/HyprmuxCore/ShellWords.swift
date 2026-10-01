/// Splits a command line into words the way a POSIX shell does for plain words:
/// whitespace separates, single quotes keep everything literal, double quotes keep
/// spaces, and a backslash escapes the next character (outside single quotes).
/// No variables, globs, or substitutions. Nil for an unterminated quote.
///
/// `new-surface --type app -- "/Applications/Visual Studio Code.app" --flag`
public func shellWords(_ line: String) -> [String]? {
    var words: [String] = []
    var word = ""
    var inWord = false
    var quote: Character?
    var escaped = false
    for c in line {
        if escaped {
            word.append(c); escaped = false; inWord = true
            continue
        }
        switch (quote, c) {
        case ("'", "'"), ("\"", "\""):
            quote = nil
        case ("'", _):
            word.append(c)
        case ("\"", "\\"), (nil, "\\"):
            escaped = true
        case ("\"", _):
            word.append(c)
        case (nil, "'"), (nil, "\""):
            quote = c; inWord = true
        case (nil, " "), (nil, "\t"), (nil, "\n"):
            if inWord { words.append(word); word = ""; inWord = false }
        default:
            word.append(c); inWord = true
        }
    }
    guard quote == nil, !escaped else { return nil }
    if inWord { words.append(word) }
    return words
}

/// The inverse of `shellWords`: quotes a word only when it needs it.
public func shellQuote(_ word: String) -> String {
    let plain = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
    return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
