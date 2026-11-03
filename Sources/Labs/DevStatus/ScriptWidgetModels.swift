import Foundation

// Pure logic for Script widgets (xbar-style): the saved configuration, the
// rules for intervals and timeouts, output parsing and the ticker presets.
// Foundation only, so the test harness compiles it on its own.

struct ScriptWidgetConfig: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    /// Run with /bin/zsh -lc, so your PATH and aliases from a login shell apply.
    var command: String
    var intervalSeconds: Int
    var timeoutSeconds: Int
    /// Keep its first line in the island wings, refreshed while the drawer is
    /// closed (opt-in per script; still never faster than the interval).
    var showsInWings = false
    /// The user saw this exact command and chose Run once. A changed command
    /// asks again.
    var approvedCommand: String?

    var isApproved: Bool { approvedCommand == command }

    static let minimumInterval = 60
    static let maximumInterval = 24 * 3600
    static let minimumTimeout = 2
    static let maximumTimeout = 30

    /// The interval floor (60 s) and timeout ceiling (30 s, and below the interval).
    func normalized() -> ScriptWidgetConfig {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.title.isEmpty { copy.title = "Script" }
        copy.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.intervalSeconds = min(max(intervalSeconds, Self.minimumInterval), Self.maximumInterval)
        copy.timeoutSeconds = min(max(timeoutSeconds, Self.minimumTimeout), Self.maximumTimeout)
        return copy
    }
}

/// What a run produced, ready to draw.
struct ScriptOutput: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var text: String
        /// `| href=https://…`: clicking opens it (http and https only).
        var link: URL?
        /// `| color=red` (red, green, orange, yellow, blue, gray, or #rrggbb).
        var color: String?
    }

    var headline: Line?
    var body: [Line] = []
    /// Lines after `---`: the widget's context menu.
    var menu: [Line] = []

    static let byteLimit = 4096

    /// xbar conventions: the first line is the headline (several lines before
    /// `---` cycle in xbar; here the rest are body lines), lines after the
    /// first `---` become menu items, `| key=value` sets parameters. ANSI
    /// escapes are removed and output is capped.
    static func parse(_ raw: String) -> ScriptOutput {
        let clean = stripANSI(String(raw.prefix(byteLimit)))
        var output = ScriptOutput()
        var inMenu = false
        for rawLine in clean.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if output.headline != nil { inMenu = true }
                continue
            }
            if trimmed.isEmpty { continue }
            let line = parseLine(trimmed)
            if inMenu {
                if output.menu.count < 20 { output.menu.append(line) }
            } else if output.headline == nil {
                output.headline = line
            } else if output.body.count < 12 {
                output.body.append(line)
            }
        }
        return output
    }

    static func parseLine(_ text: String) -> Line {
        guard let bar = text.range(of: " | ") ?? text.range(of: "|", options: .backwards) else {
            return Line(text: text, link: nil, color: nil)
        }
        let label = text[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
        let parameters = text[bar.upperBound...]
        var link: URL?
        var color: String?
        for part in parameters.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "href":
                if let url = URL(string: pair[1]), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" { link = url }
            case "color":
                color = pair[1].lowercased()
            default:
                break
            }
        }
        return Line(text: label.isEmpty ? text : label, link: link, color: color)
    }

    static func stripANSI(_ text: String) -> String {
        var result = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                // CSI: ESC [ ... final byte in @...~ ; OSC: ESC ] ... BEL
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let c = iterator.next(), !(0x40...0x7E).contains(c.value) {}
                } else if next == "]" {
                    while let c = iterator.next(), c != "\u{07}" {}
                }
                continue
            }
            if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

/// Ready-made scripts. No stock quote API is free, keyless and reliable
/// (Stooq's CSV endpoint is gone, Yahoo's is unofficial and rate-limits), so
/// tickers are Script presets: crypto prices from CoinGecko's keyless public
/// API work as is; the stock preset is a template for your own provider.
enum ScriptPresets {
    struct Preset: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let command: String
        let interval: Int
        /// Needs editing before it works (a key, a symbol list).
        let isTemplate: Bool
        /// Sends a request off this Mac.
        let usesNetwork: Bool
    }

    /// Ticker symbols for common CoinGecko ids ("bitcoin" -> "BTC"); other
    /// ids show their first four letters.
    static let cryptoSymbols: [(id: String, symbol: String)] = [
        ("bitcoin", "BTC"), ("ethereum", "ETH"), ("solana", "SOL"), ("ripple", "XRP"), ("cardano", "ADA"),
        ("dogecoin", "DOGE"), ("litecoin", "LTC"), ("polkadot", "DOT"), ("tether", "USDT"), ("usd-coin", "USDC"),
    ]

    /// A jq `sym` function mapping an id to its symbol.
    static var jqSymbols: String {
        let map = cryptoSymbols.map { "\"\($0.id)\":\"\($0.symbol)\"" }.joined(separator: ",")
        return "def sym: ({\(map)}[.] // (ascii_upcase | .[0:4]));"
    }

    /// Prices like "BTC 67k ▼1.2%  ETH 3k ▲2.3%" (the wing shows the first).
    static func crypto(_ ids: [String], currency: String = "usd") -> String {
        let list = ids.map { $0.lowercased() }.joined(separator: ",")
        let cur = currency.lowercased()
        return """
        curl -fsS --max-time 8 'https://api.coingecko.com/api/v3/simple/price?ids=\(list)&vs_currencies=\(cur)&include_24hr_change=true' \
        | /usr/bin/jq -r '\(jqSymbols) def short: if . >= 1000 then "\\((. / 100 | round) / 10)k" elif . >= 1 then "\\((. * 100 | round) / 100)" else "\\((. * 10000 | round) / 10000)" end; to_entries | map("\\(.key|sym) \\(.value.\(cur)|short) \\(if .value.\(cur)_24h_change >= 0 then "▲" else "▼" end)\\((.value.\(cur)_24h_change*10|round)/10|fabs)%") | join("  ")' \
        && echo '---' && echo 'Prices: CoinGecko (delayed, not financial advice) | href=https://www.coingecko.com'
        """
    }

    static let all: [Preset] = [
        Preset(id: "crypto", title: "Crypto Prices",
               detail: "Bitcoin and Ether from CoinGecko's free public API (no key). Delayed, not financial advice.",
               command: crypto(["bitcoin", "ethereum"]), interval: 300, isTemplate: false, usesNetwork: true),
        Preset(id: "stocks", title: "Stock Quote (your provider)",
               detail: "A template: put your own free key from Finnhub, Twelve Data or Alpha Vantage in the command.",
               command: """
               curl -fsS --max-time 8 "https://finnhub.io/api/v1/quote?symbol=AAPL&token=YOUR_KEY" \
               | /usr/bin/jq -r '"AAPL \\(.c) \\(if .dp >= 0 then "▲" else "▼" end)\\(.dp|fabs*10|round/10)%"'
               """, interval: 300, isTemplate: true, usesNetwork: true),
        Preset(id: "git", title: "Git Status",
               detail: "Branch and changed files of a folder you choose (edit the path).",
               command: "cd ~/Developer/my-project && echo \"$(git branch --show-current) · $(git status --porcelain | wc -l | tr -d ' ') changed\"",
               interval: 60, isTemplate: true, usesNetwork: false),
        Preset(id: "disk", title: "Free Disk Space",
               detail: "Free space on the startup disk.",
               command: "df -h / | awk 'NR==2 {print $4 \" free of \" $2}'",
               interval: 600, isTemplate: false, usesNetwork: false),
        Preset(id: "uptime", title: "Uptime & Load",
               detail: "How long the Mac has been up, and its load.",
               command: "uptime | sed -E 's/.*up ([^,]*), .*load averages?: (.*)/up \\1 · load \\2/'",
               interval: 300, isTemplate: false, usesNetwork: false),
    ]

    static func config(from preset: Preset) -> ScriptWidgetConfig {
        ScriptWidgetConfig(title: preset.title, command: preset.command, intervalSeconds: preset.interval, timeoutSeconds: 10)
    }
}
