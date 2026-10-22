import Foundation

/// Last line of defence for the pinned-clipboard file. The clipboard history
/// already refuses concealed and transient copies and password managers;
/// this also leaves out pinned text that *looks* like a secret, since
/// iCloud Drive is a much wider audience than this Mac's clipboard.
enum CloudSyncSecrets {
    /// Prefixes of well-known API keys and tokens.
    private static let tokenPrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "pk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_",
        "xoxb-", "xoxp-", "xoxa-", "xoxs-", "AKIA", "ASIA", "AIza", "ya29.", "glpat-", "gsk_", "hf_",
        "eyJ", // JWT
        "npm_", "pypi-", "shpat_", "SG.", "key-",
    ]

    private static let markers = [
        "-----BEGIN", "PRIVATE KEY", "password:", "password=", "passwd", "secret:", "secret=", "api_key", "apikey",
        "api-key", "access_token", "client_secret", "authorization: bearer", "otpauth://",
    ]

    /// Words that announce a secret next to them ("wifi password Abc12345",
    /// "PIN 4821", "recovery codes: …"), matched as whole words.
    private static let keywordPattern = try! NSRegularExpression(pattern: #"""
        (?ix)
        \b(?:
          pass(?:word|wort|code|phrase)s? | passwd | pwd | pin\s*code |
          cvv | cvc | security\s+code | verification\s+code | one[-\s]time\s+(?:code|password) | otp |
          2fa | mfa\s+code | (?:recovery|backup)\s+(?:codes?|keys?|phrase) | seed\s+phrase | mnemonic |
          private\s+key | secret\s+key | api\s+key | access\s+key | auth\s+token | bearer |
          ssn | social\s+security | routing\s+number | account\s+number | iban | sort\s+code
        )\b
        | \bpass\s*[:=]
        | \bpins?\s*[:=\x23]?\s*\d+
        """#)

    /// 13–19 digits, optionally grouped with spaces or dashes.
    private static let digitRunPattern = try! NSRegularExpression(pattern: #"(?<![\d])\d(?:[ -]?\d){12,18}(?![\d])"#)

    /// Apps whose copies are secrets by definition, even when pinned before
    /// the clipboard history learned to ignore them.
    static let passwordManagerPrefixes = [
        "com.agilebits.", "com.1password.", "com.bitwarden.", "com.lastpass.", "com.dashlane.", "org.keepassxc.",
        "com.keepassium.", "com.apple.Passwords", "com.apple.keychainaccess", "in.sinew.Enpass", "com.nordpass.",
        "com.keepersecurity.", "me.proton.pass", "ch.protonmail.pass", "com.roboform.",
    ]

    static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return passwordManagerPrefixes.contains { id.hasPrefix($0.lowercased()) }
    }

    static func looksSensitive(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        if markers.contains(where: { lower.contains($0.lowercased()) }) { return true }
        let range = NSRange(text.startIndex..., in: text)
        if keywordPattern.firstMatch(in: text, range: range) != nil { return true }
        // Card numbers inside a sentence ("card 4111 1111 1111 1111 exp 12/27").
        for match in digitRunPattern.matches(in: text, range: range) {
            if let r = Range(match.range, in: text),
               isCardNumber(text[r].filter { $0 != " " && $0 != "-" }) { return true }
        }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        // A single "word": token, password, card or one-time code?
        if words.count == 1 {
            let token = String(words[0])
            if tokenPrefixes.contains(where: { token.hasPrefix($0) }) && token.count >= 16 { return true }
            if isCardNumber(token) { return true }
            if looksLikePassword(token) { return true }
        }
        // Card numbers typed with spaces ("4111 1111 1111 1111").
        if text.count <= 23, isCardNumber(text.replacingOccurrences(of: " ", with: "")) { return true }
        // A short note with a password-like word in it ("wifi: Tr0ub4dor&3").
        // Sentence punctuation around a word ("Spinach,") doesn't count as a symbol.
        if words.count <= 6, words.contains(where: {
            looksLikePassword(String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’")))
        }) { return true }
        // Any embedded long high-entropy token.
        return words.contains { word in
            let w = String(word)
            return (w.count >= 20 && tokenPrefixes.contains { w.hasPrefix($0) }) || (w.count >= 32 && isHighEntropy(w))
        }
    }

    /// 8–64 characters with no spaces, mixing at least three of lower, upper,
    /// digits and symbols, and not a URL, email or path.
    static func looksLikePassword(_ s: String) -> Bool {
        guard (8...64).contains(s.count), !s.contains("://"), !s.hasPrefix("/"), !s.hasPrefix("~") else { return false }
        if s.contains("@"), s.contains("."), !s.contains(where: \.isUppercase) { return false } // email
        var classes = 0
        if s.contains(where: \.isLowercase) { classes += 1 }
        if s.contains(where: \.isUppercase) { classes += 1 }
        if s.contains(where: \.isNumber) { classes += 1 }
        if s.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        return classes >= 3 || (s.count >= 16 && isHighEntropy(s))
    }

    /// Long, varied strings (hex/base64 keys).
    static func isHighEntropy(_ s: String) -> Bool {
        guard s.count >= 16 else { return false }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        let entropy = counts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
        let hasDigit = s.contains(where: \.isNumber), hasLetter = s.contains(where: \.isLetter)
        return entropy >= 3.5 && hasDigit && hasLetter
    }

    /// 13–19 digits passing the Luhn check.
    static func isCardNumber(_ s: String) -> Bool {
        let digits = s.filter { $0 != "-" }
        guard (13...19).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
