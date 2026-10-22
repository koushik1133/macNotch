import Foundation

/// Deterministic skills dictionary: canonical names with aliases, matched on
/// word boundaries. It always runs (no model needed) and is the ground truth
/// the on-device model's suggestions are checked against.
///
/// Line format: `Canonical|alias;alias|flags` where flags may contain
/// `s` (soft skill) and `c` (case-sensitive: the name is also an everyday
/// English word, e.g. "Go", "Swift", "Excel", "R").
enum JobSkills {
    struct Skill: Sendable {
        let name: String
        let aliases: [String]
        let soft: Bool
        let caseSensitive: Bool
    }

    struct Match: Sendable, Equatable {
        let skill: String
        /// The alias as written in the text (first occurrence).
        let surface: String
        let count: Int
        let soft: Bool
    }

    static let catalog = """
    Swift||c
    SwiftUI||
    UIKit||
    AppKit||
    Objective-C|ObjC;Objective C|
    Xcode||
    Combine framework|Combine|c
    Core Data|CoreData|
    SwiftData||
    Core ML|CoreML|
    ARKit||
    Metal|Metal API|c
    StoreKit||
    XCTest||
    Swift Concurrency|async/await;structured concurrency|
    iOS||
    macOS||
    watchOS||
    tvOS||
    visionOS||
    Android||
    Kotlin||
    Jetpack Compose|Compose UI|
    Java||c
    React Native||
    Flutter||
    Dart||c
    JavaScript|JS;ECMAScript|
    TypeScript|TS|c
    Node.js|NodeJS;Node js;Node|c
    React|React.js;ReactJS|c
    Next.js|NextJS|
    Vue.js|Vue;VueJS|
    Angular|AngularJS|
    Svelte|SvelteKit|
    Redux||
    HTML|HTML5|
    CSS|CSS3|
    Sass|SCSS|
    Tailwind CSS|Tailwind|
    Webpack||
    Vite||c
    GraphQL||
    REST APIs|REST;RESTful;REST API|
    gRPC||
    WebSockets|WebSocket|
    OAuth|OAuth2;OAuth 2.0|
    Python||
    Django||
    Flask||c
    FastAPI||
    Ruby||c
    Ruby on Rails|Rails|c
    PHP||
    Laravel||
    Go|Golang|c
    Rust||c
    C++|CPP|
    C#|C Sharp|
    .NET|dotnet;ASP.NET;.NET Core|
    C|C language|c
    Scala||c
    Elixir||
    Erlang||
    Haskell||
    Perl||c
    R|R language|c
    MATLAB||
    Bash|Shell scripting;shell script|
    PowerShell||
    Spring Boot|Spring Framework|
    Microservices|microservice;micro-services|
    Distributed systems|distributed system|
    System design||
    Event-driven architecture|event driven|
    SQL||
    PostgreSQL|Postgres|
    MySQL||
    SQLite||
    Microsoft SQL Server|SQL Server;MSSQL|
    Oracle Database|Oracle DB|
    MongoDB|Mongo|
    Redis||
    Cassandra||
    DynamoDB||
    Elasticsearch|Elastic Search;OpenSearch|
    Snowflake||c
    BigQuery||
    Redshift||
    Databricks||
    Firebase||
    Supabase||
    Kafka|Apache Kafka|
    RabbitMQ||
    Spark|Apache Spark;PySpark|c
    Hadoop||
    Airflow|Apache Airflow|
    dbt|data build tool|c
    ETL|ELT|
    Data pipelines|data pipeline|
    Data warehousing|data warehouse|
    Data modeling|data modelling|
    Data analysis|data analytics;analyzing data|
    Data visualization|data viz|
    Tableau||
    Power BI|PowerBI|
    Looker||c
    Excel|Microsoft Excel;MS Excel|c
    Google Sheets||
    Statistics|statistical analysis|
    A/B testing|AB testing;experimentation;split testing|
    Machine learning|ML|c
    Deep learning||
    NLP|natural language processing|
    Computer vision||
    LLMs|LLM;large language models;large language model|
    Generative AI|GenAI;generative models|
    Prompt engineering||
    RAG|retrieval augmented generation;retrieval-augmented generation|c
    PyTorch||
    TensorFlow||
    Keras||
    scikit-learn|sklearn;scikit learn|
    Pandas||c
    NumPy||
    Jupyter|Jupyter notebooks|
    MLOps||
    Reinforcement learning||
    Recommendation systems|recommender systems|
    AWS|Amazon Web Services|
    EC2||
    S3|Amazon S3|c
    Lambda|AWS Lambda|c
    Azure|Microsoft Azure|
    GCP|Google Cloud;Google Cloud Platform|
    Docker|containers;containerization|
    Kubernetes|K8s|
    Terraform||
    Ansible||
    Helm||c
    CI/CD|CI CD;continuous integration;continuous delivery;continuous deployment|
    GitHub Actions||
    Jenkins||
    CircleCI||
    GitLab CI|GitLab|
    Fastlane||
    Git|version control|c
    Linux|Unix|
    Serverless||
    Observability|monitoring|
    Prometheus||
    Grafana||
    Datadog||
    Sentry||c
    Site reliability engineering|SRE|
    DevOps||
    Networking|TCP/IP|c
    Security|application security;AppSec;information security;cybersecurity|c
    Penetration testing|pentesting|
    Cryptography|encryption|
    IAM|identity and access management|c
    Unit testing|unit tests|
    Integration testing|integration tests|
    Test automation|automated testing;automation testing|
    Selenium||
    Cypress||c
    Playwright||c
    Jest||c
    QA|quality assurance|c
    Performance optimization|performance tuning;profiling|
    Accessibility|a11y;WCAG|
    Localization|internationalization;i18n;l10n|
    Agile|Scrum;Kanban|
    Jira||
    Confluence||
    Figma||
    Sketch|Sketch app|c
    Adobe XD||
    Photoshop|Adobe Photoshop|
    Illustrator|Adobe Illustrator|c
    UI design|user interface design;visual design|
    UX design|user experience design;UX|
    User research|usability testing|
    Prototyping|prototypes|
    Design systems|design system|
    Wireframing|wireframes|
    Product management|product manager|
    Product strategy||
    Roadmapping|roadmap|
    Stakeholder management|stakeholders|
    Project management|project manager|
    Program management||
    PMP||
    Six Sigma||
    Salesforce||
    HubSpot||
    CRM||
    SEO|search engine optimization|
    SEM|search engine marketing;paid search|
    Google Analytics|GA4|
    Content marketing||
    Copywriting||
    Social media marketing|social media|
    Email marketing||
    Growth marketing|growth hacking|
    Sales|B2B sales;account executive|c
    Business development||
    Customer success||
    Financial modeling|financial modelling|
    Accounting|GAAP|
    Budgeting|forecasting|
    SAP||
    Supply chain||
    Recruiting|talent acquisition;sourcing candidates|
    HRIS||
    Technical writing||
    Blockchain|Web3|
    Solidity||
    Embedded systems|embedded software|
    Firmware||
    Robotics||
    Unity||c
    Unreal Engine|Unreal|
    Game development|game dev|
    Video processing|AVFoundation|
    Bluetooth|BLE;Core Bluetooth|
    Push notifications|APNs|
    In-app purchases|IAP|
    App Store|App Store Connect;TestFlight|
    Mobile development|mobile apps;mobile engineering|
    Frontend development|front-end;frontend|
    Backend development|back-end;backend|
    Full-stack development|full stack;full-stack|
    API design|API development|
    Code review|code reviews|
    Mentoring|mentorship;coaching|s
    Leadership|led a team;team lead;people management|s
    Communication|communication skills;written and verbal communication|s
    Collaboration|cross-functional;cross functional;teamwork|s
    Problem solving|problem-solving|s
    Ownership|take ownership;end-to-end ownership|s
    Attention to detail|detail-oriented|s
    Time management||s
    Adaptability||s
    Critical thinking||s
    Customer focus|customer-centric;customer obsession|s
    Presentation skills|presenting|s
    Negotiation||s
    Spanish||c
    French||c
    German||c
    Mandarin||c
    """

    static let skills: [Skill] = catalog
        .split(separator: "\n")
        .compactMap { raw -> Skill? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let aliases = parts.count > 1 ? parts[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } : []
            let flags = parts.count > 2 ? parts[2] : ""
            return Skill(name: name, aliases: [name] + aliases.filter { !$0.isEmpty },
                         soft: flags.contains("s"), caseSensitive: flags.contains("c"))
        }

    private struct Compiled: @unchecked Sendable {
        let skill: Skill
        let regexes: [NSRegularExpression]
    }

    private static let compiled: [Compiled] = skills.map { skill in
        let regexes = skill.aliases.compactMap { alias -> NSRegularExpression? in
            let escaped = NSRegularExpression.escapedPattern(for: alias)
                .replacingOccurrences(of: "\\ ", with: "[\\s\\-]+")
                .replacingOccurrences(of: " ", with: "[\\s\\-]+")
            // Not glued to other word characters (".NET" ok, "C" not in "C-level"
            // handled by the case/next-char rule, "Swift." ends a sentence).
            var pattern = "(?<![A-Za-z0-9+#])" + escaped + "(?![A-Za-z0-9+#]|\\.[A-Za-z0-9])"
            // One-letter languages only inside a list ("C, C++", "Python/R").
            if alias == "C" || alias == "R" {
                pattern = "(?<=[,/(;:]|[,/(;:] |^)" + alias + "(?=\\s*(?:[,/);]|and\\b|or\\b|$))"
            }
            // "Core ML" / "Create ML" are Apple frameworks, not machine learning in general.
            if alias == "ML" { pattern = "(?<!Core |Create |Core|Create)" + pattern }
            if alias == "Go" { pattern = "(?<![A-Za-z0-9])Go(?![A-Za-z0-9\\-]|\\s+(?:to|ahead|beyond|live|above|further|back|out)\\b)" }
            let caseInsensitive = !skill.caseSensitive && alias.count > 2
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if caseInsensitive { options.insert(.caseInsensitive) }
            return try? NSRegularExpression(pattern: pattern, options: options)
        }
        return Compiled(skill: skill, regexes: regexes)
    }

    /// All dictionary skills in `text`, most frequent first.
    static func find(in text: String) -> [Match] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var results: [Match] = []
        for entry in compiled {
            var count = 0
            var firstLocation = Int.max
            var surface = ""
            for regex in entry.regexes {
                let matches = regex.matches(in: text, range: range)
                count += matches.count
                if let first = matches.first, first.range.location < firstLocation {
                    firstLocation = first.range.location
                    surface = ns.substring(with: first.range)
                }
            }
            if count > 0 {
                results.append(Match(skill: entry.skill.name, surface: surface, count: count, soft: entry.skill.soft))
            }
        }
        // "React Native" also matches "React"; "Ruby on Rails" matches "Ruby".
        let names = Set(results.map(\.skill))
        results.removeAll { match in
            (match.skill == "React" && names.contains("React Native") && countOf("React", excluding: "React Native", in: text) == 0)
            || (match.skill == "Ruby" && names.contains("Ruby on Rails") && countOf("Ruby", excluding: "Ruby on Rails", in: text) == 0)
        }
        return results.sorted { $0.count == $1.count ? $0.skill < $1.skill : $0.count > $1.count }
    }

    /// Canonical skill names in `text` (hard skills only when `hardOnly`).
    static func names(in text: String, hardOnly: Bool = false) -> [String] {
        find(in: text).filter { !hardOnly || !$0.soft }.map(\.skill)
    }

    static func isSoft(_ name: String) -> Bool {
        skills.first { $0.name == name }?.soft ?? false
    }

    /// Canonical name for a free-form skill ("ReactJS" → "React"), or nil.
    static func canonical(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "+#./"))))
        guard !trimmed.isEmpty else { return nil }
        for skill in skills {
            for alias in skill.aliases {
                if skill.caseSensitive || alias.count <= 2 {
                    if alias == trimmed { return skill.name }
                } else if alias.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return skill.name
                }
            }
        }
        return nil
    }

    /// Aliases of a canonical skill (including the name).
    static func aliases(of name: String) -> [String] {
        skills.first { $0.name == name }?.aliases ?? [name]
    }

    /// Whole-word occurrences of `word` that are not part of `excluding`.
    private static func countOf(_ word: String, excluding: String?, in text: String) -> Int {
        let pattern = "(?<![A-Za-z0-9+#])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9+#])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        let ns = text as NSString
        var count = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let excluding {
                let start = match.range.location
                let length = min((excluding as NSString).length, ns.length - start)
                if length > 0, ns.substring(with: NSRange(location: start, length: length)).caseInsensitiveCompare(excluding) == .orderedSame {
                    continue
                }
            }
            count += 1
        }
        return count
    }
}

// MARK: - Keywords

/// Jobscan-style "other keywords": frequent content words and bigrams of the
/// JD, checked for exact (stemmed) presence in the resume.
enum JobKeywords {
    static let stopwords: Set<String> = Set("""
    a about above after again against all also am an and any are as at be because been before being below between both but by can could did do does doing down during each few for from further had has have having he her here hers herself him himself his how i if in into is it its itself just me more most my myself no nor not now of off on once only or other our ours ourselves out over own same she should so some such than that the their theirs them themselves then there these they this those through to too under until up very was we were what when where which while who whom why will with would you your yours yourself yourselves us etc via per within across including include includes like well new using use used must may might shall able ability strong excellent good great plus preferred required requirements requirement qualifications qualification responsibilities responsibility experience experienced years year work working team teams role job position company candidate candidates opportunity apply join help make build building ensure across based level skills skill knowledge understanding demonstrated proven familiarity familiar comfortable hands-on day days time high highly closely environment world best bonus benefits salary equal employer status gender race religion disability veteran applicants application applications please related relevant similar field degree bachelor bachelors master masters phd equivalent minimum least one two three four five six seven eight nine ten looking want wants will we're you'll you're our we've who's it's that's they're need needs ideal ideally key including other others every each
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#-/")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-/")) }
            .filter { !$0.isEmpty }
    }

    static func stem(_ word: String) -> String {
        var w = word
        for suffix in ["ing", "ies", "ed", "es", "s"] where w.count > suffix.count + 3 && w.hasSuffix(suffix) {
            w.removeLast(suffix.count)
            if suffix == "ies" { w += "y" }
            break
        }
        return w
    }

    /// Top JD keywords (unigrams ≥ 2 occurrences and bigrams ≥ 2), most frequent first.
    static func top(in text: String, limit: Int = 20) -> [String] {
        let tokens = words(text)
        var unigram: [String: Int] = [:]
        var display: [String: String] = [:]
        for token in tokens where token.count >= 3 && !stopwords.contains(token) && Int(token) == nil {
            let key = stem(token)
            unigram[key, default: 0] += 1
            if display[key] == nil { display[key] = token }
        }
        var bigram: [String: Int] = [:]
        for index in tokens.indices.dropLast() {
            let a = tokens[index], b = tokens[index + 1]
            guard a.count >= 3, b.count >= 3, !stopwords.contains(a), !stopwords.contains(b),
                  Int(a) == nil, Int(b) == nil else { continue }
            bigram["\(a) \(b)", default: 0] += 1
        }
        var scored: [(String, Double)] = []
        for (key, count) in unigram where count >= 2 {
            scored.append((display[key] ?? key, Double(count)))
        }
        for (phrase, count) in bigram where count >= 2 {
            scored.append((phrase, Double(count) * 1.5))
        }
        // A bigram makes its unigrams redundant.
        let chosenBigrams = Set(scored.filter { $0.0.contains(" ") }.flatMap { $0.0.split(separator: " ").map { stem(String($0)) } })
        scored.removeAll { !$0.0.contains(" ") && chosenBigrams.contains(stem($0.0)) && $0.1 < 4 }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// True when every word of `keyword` (stemmed) appears in the resume.
    static func present(_ keyword: String, inStems stems: Set<String>) -> Bool {
        keyword.split(separator: " ").allSatisfy { stems.contains(stem(String($0))) }
    }

    static func stems(_ text: String) -> Set<String> {
        Set(words(text).map(stem))
    }
}
