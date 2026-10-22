import Foundation

/// Fuzzy matching and scoring after fzf (github.com/junegunn/fzf,
/// src/algo/algo.go, MIT, © Junegunn Choi): the same score constants,
/// character classes and boundary/camelCase/consecutive bonuses, the V1
/// forward + backward scan to find a short span, and an exact-substring
/// pass that keeps the best-scoring occurrence. Reimplemented in Swift for
/// short fields (titles, keywords); long bodies use word-prefix matching in
/// `UniversalSearchEngine` instead, as Raycast and Alfred do.
enum UniversalSearchFuzzy {
    struct Match: Equatable, Sendable {
        var score: Int
        /// Matched character offsets in the text.
        var positions: [Int]
        /// Bonus earned by the first pattern character (boundary quality).
        var firstBonus: Int
    }

    enum CharClass: Int, Sendable {
        case white = 0
        case nonWord
        case delimiter
        case lower
        case upper
        case letter
        case number
    }

    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    static let bonusBoundary = scoreMatch / 2
    static let bonusNonWord = scoreMatch / 2
    static let bonusCamel123 = bonusBoundary + scoreGapExtension
    static let bonusConsecutive = -(scoreGapStart + scoreGapExtension)
    static let bonusFirstCharMultiplier = 2
    static let bonusBoundaryWhite = bonusBoundary + 2
    static let bonusBoundaryDelimiter = bonusBoundary + 1

    static func charClass(_ c: Character) -> CharClass {
        if let a = c.asciiValue {
            switch a {
            case 97...122: return .lower
            case 65...90: return .upper
            case 48...57: return .number
            case 32, 9, 10, 11, 12, 13: return .white
            case 47, 44, 58, 59, 124: return .delimiter // / , : ; |
            default: return .nonWord
            }
        }
        if c.isWhitespace { return .white }
        if c.isLowercase { return .lower }
        if c.isUppercase { return .upper }
        if c.isNumber { return .number }
        if c.isLetter { return .letter }
        return .nonWord
    }

    static func bonus(prev: CharClass, current: CharClass) -> Int {
        if current.rawValue > CharClass.nonWord.rawValue {
            switch prev {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if (prev == .lower && current == .upper) || (prev != .number && current == .number) {
            return bonusCamel123
        }
        switch current {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    /// Best match of `pattern` (already folded) in `text`, whose folded copy
    /// is `folded` (same length). Nil when the characters don't appear in order.
    static func match(_ pattern: [Character], text: [Character], folded: [Character]) -> Match? {
        let n = folded.count, m = pattern.count
        guard m > 0, m <= n, text.count == n else { return nil }

        // Exact occurrences first: the best-scoring one wins (fzf's
        // ExactMatchNaive picks the occurrence with the highest bonus).
        var best: Match?
        var occurrences = 0
        if m > 1 {
            var start = 0
            while start <= n - m, occurrences < 32 {
                if folded[start] == pattern[0] {
                    var k = 1
                    while k < m, folded[start + k] == pattern[k] { k += 1 }
                    if k == m {
                        occurrences += 1
                        let candidate = score(pattern, text: text, folded: folded, from: start, to: start + m)
                        if best == nil || candidate.score > best!.score { best = candidate }
                    }
                }
                start += 1
            }
            if let best { return best }
        }

        // V1: forward scan for the first in-order occurrence…
        var pidx = 0, sidx = -1, eidx = -1
        for i in 0..<n where folded[i] == pattern[pidx] {
            if sidx < 0 { sidx = i }
            pidx += 1
            if pidx == m {
                eidx = i + 1
                break
            }
        }
        guard sidx >= 0, eidx > 0 else { return nil }
        // …then backward from its end for a shorter span.
        pidx = m - 1
        var i = eidx - 1
        while i >= sidx {
            if folded[i] == pattern[pidx] {
                pidx -= 1
                if pidx < 0 {
                    sidx = i
                    break
                }
            }
            i -= 1
        }
        return score(pattern, text: text, folded: folded, from: sidx, to: eidx)
    }

    /// fzf's calculateScore over text[from..<to].
    static func score(_ pattern: [Character], text: [Character], folded: [Character], from: Int, to: Int) -> Match {
        var pidx = 0, total = 0, consecutive = 0, firstBonus = 0, firstCharBonus = 0
        var inGap = false
        var prevClass: CharClass = from > 0 ? charClass(text[from - 1]) : .white
        var positions: [Int] = []
        positions.reserveCapacity(pattern.count)
        var idx = from
        while idx < to {
            let cls = charClass(text[idx])
            if pidx < pattern.count, folded[idx] == pattern[pidx] {
                total += scoreMatch
                var b = bonus(prev: prevClass, current: cls)
                if consecutive == 0 {
                    firstBonus = b
                } else {
                    if b >= bonusBoundary, b > firstBonus { firstBonus = b }
                    b = max(b, firstBonus, bonusConsecutive)
                }
                if pidx == 0 {
                    total += b * bonusFirstCharMultiplier
                    firstCharBonus = b
                } else {
                    total += b
                }
                inGap = false
                consecutive += 1
                pidx += 1
                positions.append(idx)
            } else {
                total += inGap ? scoreGapExtension : scoreGapStart
                inGap = true
                consecutive = 0
                firstBonus = 0
            }
            prevClass = cls
            idx += 1
        }
        return Match(score: total, positions: positions, firstBonus: firstCharBonus)
    }

    /// Highest score a pattern of this length can reach (all consecutive,
    /// starting on a white-space boundary): used to normalize.
    static func idealScore(length m: Int) -> Int {
        guard m > 0 else { return 0 }
        return m * scoreMatch + bonusBoundaryWhite * bonusFirstCharMultiplier + (m - 1) * bonusBoundaryWhite
    }
}
