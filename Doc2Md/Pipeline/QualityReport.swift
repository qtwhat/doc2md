import Foundation
import Vision

// MARK: - Data Types

struct PageOCRResult {
    let pageNumber: Int
    let text: String
    let observations: [VNRecognizedTextObservation]
    let averageConfidence: Float
}

struct SuspiciousToken {
    let token: String
    let page: Int
    let line: Int
    let context: String
}

struct CorrectionRecord {
    let original: String
    let corrected: String
    var count: Int
}

// MARK: - QualityReport

class QualityReport {
    var pageResults: [PageOCRResult] = []
    var suspiciousTokens: [SuspiciousToken] = []
    var corrections: [String: CorrectionRecord] = [:]
    let fileName: String
    var outputFiles: [(name: String, sizeKB: Int)] = []

    init(fileName: String) {
        self.fileName = fileName
    }

    // MARK: - Analysis

    /// Analyze OCR output for a single page, collecting confidence and suspicious tokens.
    func analyzeText(_ text: String, page: Int, observations: [VNRecognizedTextObservation]) {
        let avgConf: Float
        if observations.isEmpty {
            avgConf = 0.0
        } else {
            avgConf = observations.reduce(Float(0)) { $0 + $1.confidence } / Float(observations.count)
        }

        let result = PageOCRResult(
            pageNumber: page,
            text: text,
            observations: observations,
            averageConfidence: avgConf
        )
        pageResults.append(result)

        // Scan each line for suspicious tokens
        let lines = text.components(separatedBy: .newlines)
        for (lineIndex, line) in lines.enumerated() {
            let words = tokenize(line)
            for word in words {
                let cleaned = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                guard cleaned.count >= 2 else { continue }
                if !isKnownWord(cleaned) && !isTechnicalTerm(cleaned) {
                    let ctx = buildContext(for: word, in: line)
                    let suspicious = SuspiciousToken(
                        token: cleaned,
                        page: page,
                        line: lineIndex + 1,
                        context: ctx
                    )
                    suspiciousTokens.append(suspicious)
                }
            }
        }
    }

    /// Record a correction made by the post-processing pipeline.
    func recordCorrection(original: String, corrected: String) {
        let key = "\(original)->\(corrected)"
        if var existing = corrections[key] {
            existing.count += 1
            corrections[key] = existing
        } else {
            corrections[key] = CorrectionRecord(original: original, corrected: corrected, count: 1)
        }
    }

    /// Register an output file for inclusion in the report.
    func addOutputFile(name: String, sizeKB: Int) {
        outputFiles.append((name: name, sizeKB: sizeKB))
    }

    // MARK: - Report Generation

    func generateReport() -> String {
        var lines: [String] = []

        let totalWords = pageResults.reduce(0) { $0 + wordCount($1.text) }
        let suspiciousCount = suspiciousTokens.count
        let suspiciousPercent = totalWords > 0
            ? Double(suspiciousCount) / Double(totalWords) * 100.0
            : 0.0

        lines.append("=== OCR Quality Report: \(fileName) ===")
        lines.append("Pages processed: \(pageResults.count)")
        lines.append("Total words: \(formatNumber(totalWords))")
        lines.append("Suspicious tokens: \(suspiciousCount) (\(String(format: "%.2f", suspiciousPercent))%)")
        lines.append("")

        // Per-page confidence
        lines.append("Per-page confidence:")
        for result in pageResults.sorted(by: { $0.pageNumber < $1.pageNumber }) {
            let conf = result.averageConfidence
            let marker: String
            if conf < 0.80 {
                marker = "\u{26A0}\u{FE0F}"  // warning sign
            } else {
                marker = "\u{2713}"  // check mark
            }
            var entry = "  Page \(result.pageNumber): avg \(String(format: "%.2f", conf)) \(marker)"
            if conf < 0.80 && result.pageNumber == 1 {
                entry += " (cover page - layout complexity)"
            }
            lines.append(entry)
        }
        lines.append("")

        // Suspicious tokens (show up to 50)
        if !suspiciousTokens.isEmpty {
            lines.append("Suspicious tokens:")
            let limit = min(suspiciousTokens.count, 50)
            for i in 0..<limit {
                let t = suspiciousTokens[i]
                lines.append("  Page \(t.page), Line \(t.line): \"\(t.token)\" (context: ...\(t.context)...)")
            }
            if suspiciousTokens.count > 50 {
                lines.append("  ... and \(suspiciousTokens.count - 50) more")
            }
            lines.append("")
        }

        // Corrections
        let totalCorrections = corrections.values.reduce(0) { $0 + $1.count }
        if totalCorrections > 0 {
            lines.append("Corrections applied: \(totalCorrections)")
            let sorted = corrections.values.sorted { $0.count > $1.count }
            for record in sorted {
                lines.append("  \(record.original) \u{2192} \(record.corrected) (\(record.count) occurrence\(record.count == 1 ? "" : "s"))")
            }
            lines.append("")
        }

        // Output files
        if !outputFiles.isEmpty {
            lines.append("Files output:")
            for file in outputFiles {
                lines.append("  - \(file.name) (\(file.sizeKB) KB)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Save the report to disk next to the given output file URL.
    @discardableResult
    func saveReport(nextTo outputURL: URL) -> URL? {
        let reportName = outputURL.deletingPathExtension().lastPathComponent + "_quality_report.txt"
        let reportURL = outputURL.deletingLastPathComponent().appendingPathComponent(reportName)
        let content = generateReport()
        do {
            try content.write(to: reportURL, atomically: true, encoding: .utf8)
            return reportURL
        } catch {
            print("[QualityReport] Failed to save report: \(error)")
            return nil
        }
    }

    // MARK: - Technical Term Detection

    /// Returns true if the word is a recognized technical term (3GPP, spec references, etc.).
    func isTechnicalTerm(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }

        // 1. Pure number or hex value (e.g. 0xFF, 123, 3.14)
        if w.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^0[xX][0-9a-fA-F]+$"#, options: .regularExpression) != nil { return true }

        // 2. All-caps abbreviation, 2-10 characters (UE, gNB, RRC, MCCH, PTM, etc.)
        if w.range(of: #"^[A-Z][A-Z0-9]{1,9}$"#, options: .regularExpression) != nil { return true }
        // gNB-style (lowercase prefix + uppercase)
        if w.range(of: #"^[a-z][A-Z][A-Za-z0-9]{0,8}$"#, options: .regularExpression) != nil { return true }

        // 3. Underscore-separated uppercase (RRC_CONNECTED, RRC_INACTIVE, etc.)
        if w.range(of: #"^[A-Z][A-Z0-9]*(_[A-Z][A-Z0-9]*)+$"#, options: .regularExpression) != nil { return true }

        // 4. Spec IDs: TS 38.331, TR 23.700-xx, PCT/CN2022/...
        if w.range(of: #"^(TS|TR)\s*[0-9]{2}\.[0-9]+"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^PCT/[A-Z]{2}[0-9/]+"#, options: .regularExpression) != nil { return true }
        if w.range(of: #"^[0-9]{2}\.[0-9]{3}"#, options: .regularExpression) != nil { return true }

        // 5. Paragraph numbers: [0001], [0123]
        if w.range(of: #"^\[[0-9]{3,5}\]$"#, options: .regularExpression) != nil { return true }

        // 6. R-doc references: R2-2507135, S2-1234567
        if w.range(of: #"^[A-Z][0-9]-[0-9]{6,7}$"#, options: .regularExpression) != nil { return true }

        // 7. Hyphenated technical terms (e.g., NR-U, C-RNTI, I-RNTI, UP-CIoT)
        if w.range(of: #"^[A-Z0-9]+-[A-Z][A-Za-z0-9]*$"#, options: .regularExpression) != nil { return true }

        // 8. Known 3GPP / telecom whitelist
        if Self.technicalWhitelist.contains(w.lowercased()) { return true }

        return false
    }

    // MARK: - Private Helpers

    private func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private func wordCount(_ text: String) -> Int {
        tokenize(text).count
    }

    private func isKnownWord(_ word: String) -> Bool {
        Self.commonWords.contains(word.lowercased())
    }

    private func buildContext(for word: String, in line: String, windowChars: Int = 30) -> String {
        guard let range = line.range(of: word) else { return word }
        let start = line.index(range.lowerBound, offsetBy: -windowChars, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(range.upperBound, offsetBy: windowChars, limitedBy: line.endIndex) ?? line.endIndex
        return String(line[start..<end])
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - 3GPP / Telecom Technical Whitelist

    private static let technicalWhitelist: Set<String> = [
        // RRC states and procedures
        "rrc", "rrc_connected", "rrc_inactive", "rrc_idle",
        "ue", "gnb", "enb", "ng-ran", "e-utran", "nr",
        "ptm", "mcch", "mtch", "mbms", "mbs",
        "drx", "wus", "bwp", "srs", "csi", "harq", "arq",
        "pdcp", "rlc", "mac", "phy", "sdap", "nas",
        "pdcch", "pdsch", "pucch", "pusch", "prach",
        "sib", "mib", "bcch", "ccch", "dcch", "dtch",
        "rnti", "c-rnti", "i-rnti", "tc-rnti", "ra-rnti",
        "rna", "ran", "cn", "amf", "smf", "upf", "nrf",
        "ngap", "xnap", "f1ap", "e1ap", "s1ap", "x2ap",
        "scg", "mcg", "pscell", "spcell", "pcell", "scell",
        "sdt", "edt", "ciot", "up-ciot", "cp-ciot",
        "dci", "uci", "tti", "ofdm", "ofdma", "mimo", "mu-mimo",
        "sinr", "rsrp", "rsrq", "rssi",
        "qos", "qci", "5qi", "ambr", "mfbr", "gfbr",
        "plmn", "tai", "guti", "tmsi", "imsi", "supi", "suci",
        "pdu", "sdu", "tbs", "mcs", "cqi", "ri", "pmi",
        "drb", "srb", "lcid", "lch",
        "ho", "cho", "daps", "mro", "mlb",
        "cag", "ntn", "iab", "sidelink", "v2x", "prose",
        "nssai", "s-nssai", "nsi", "nssp",
        "bwp", "coreset", "dmrs", "ptrs",
        "fr1", "fr2", "mmwave", "sub-6",
        "rel-18", "rel-19", "rel-20",
        "3gpp", "etsi", "ietf", "ieee",
        "lte", "wcdma", "gsm", "umts", "hsdpa", "hsupa",
        "eps", "5gc", "5gs", "epc", "ngc",
        "mec", "urllc", "embb", "mmtc", "redcap",
        "ca", "dc", "en-dc", "nsa", "sa",
        "arfcn", "earfcn", "nrarfcn",
        "ta", "TA", "pci", "ssb", "cgi",
        "rach", "cbra", "cfra", "msg1", "msg2", "msg3", "msg4",
        "msga", "msgb",
        "sr", "bsr", "phr",
        "rlf", "rlm", "bfd", "cbd",
        "cu", "du", "ru", "ric", "o-ran",
        "ng", "xn", "f1", "e1", "uu",
        "rohc", "sdnv", "ip", "tcp", "udp",
        "paging", "etws", "cmas", "pws",
    ]

    // MARK: - Common English Words (~2500 most frequent)

    static let commonWords: Set<String> = {
        return [
            // Articles, pronouns, prepositions, conjunctions, auxiliaries
            "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
            "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
            "this", "but", "his", "by", "from", "they", "we", "her", "she", "or",
            "an", "will", "my", "one", "all", "would", "there", "their", "what", "so",
            "up", "out", "if", "about", "who", "get", "which", "go", "me", "when",
            "make", "can", "like", "time", "no", "just", "him", "know", "take", "people",
            "into", "year", "your", "good", "some", "could", "them", "see", "other", "than",
            "then", "now", "look", "only", "come", "its", "over", "think", "also", "back",
            "after", "use", "two", "how", "our", "work", "first", "well", "way", "even",
            "new", "want", "because", "any", "these", "give", "day", "most", "us",

            // Common verbs
            "said", "say", "tell", "told", "ask", "asked", "try", "tried", "need", "needed",
            "feel", "felt", "become", "became", "leave", "left", "put", "mean", "meant",
            "keep", "kept", "let", "begin", "began", "seem", "seemed", "help", "helped",
            "show", "showed", "shown", "hear", "heard", "play", "played", "run", "ran",
            "move", "moved", "live", "lived", "believe", "believed", "hold", "held",
            "bring", "brought", "happen", "happened", "write", "wrote", "written",
            "provide", "provided", "sit", "sat", "stand", "stood", "lose", "lost",
            "pay", "paid", "meet", "met", "include", "included", "continue", "continued",
            "set", "learn", "learned", "change", "changed", "lead", "led", "understand",
            "understood", "watch", "watched", "follow", "followed", "stop", "stopped",
            "create", "created", "speak", "spoke", "spoken", "read", "allow", "allowed",
            "add", "added", "spend", "spent", "grow", "grew", "grown", "open", "opened",
            "walk", "walked", "win", "won", "offer", "offered", "remember", "remembered",
            "love", "loved", "consider", "considered", "appear", "appeared", "buy", "bought",
            "wait", "waited", "serve", "served", "die", "died", "send", "sent",
            "expect", "expected", "build", "built", "stay", "stayed", "fall", "fell",
            "cut", "reach", "reached", "kill", "killed", "remain", "remained",
            "suggest", "suggested", "raise", "raised", "pass", "passed", "sell", "sold",
            "require", "required", "report", "reported", "decide", "decided", "pull", "pulled",
            "develop", "developed", "support", "supported",

            // Common nouns
            "people", "time", "way", "year", "day", "thing", "man", "woman", "child",
            "world", "life", "hand", "part", "place", "case", "week", "company", "system",
            "program", "question", "work", "government", "number", "night", "point", "home",
            "water", "room", "mother", "area", "money", "story", "fact", "month", "lot",
            "right", "study", "book", "eye", "job", "word", "business", "issue", "side",
            "kind", "head", "house", "service", "friend", "father", "power", "hour", "game",
            "line", "end", "member", "members", "law", "car", "city", "community", "name",
            "president", "team", "minute", "idea", "body", "information", "river",
            "land", "back", "process", "turn", "course", "face", "education",
            "history", "effect", "result", "change", "order", "reason",
            "research", "girl", "guy", "moment", "air", "teacher", "force", "offer",
            "group", "problem", "development", "country", "experience", "student",
            "school", "state", "family", "interest", "level", "need", "office",
            "door", "health", "person", "art", "war", "party", "age",
            "market", "music", "form", "plan", "report", "view",
            "field", "police", "matter", "record", "table", "rate", "value",
            "half", "food", "street", "voice", "paper", "heart", "class",

            // Common adjectives
            "good", "new", "first", "last", "long", "great", "little", "own", "old",
            "right", "big", "high", "different", "small", "large", "next", "early",
            "young", "important", "few", "public", "bad", "same", "able", "free",
            "sure", "real", "full", "special", "easy", "clear", "recent", "certain",
            "personal", "open", "red", "hard", "available", "particular", "short",
            "white", "whole", "possible", "low", "late", "general", "social",
            "human", "local", "political", "strong", "true", "international",
            "major", "better", "best", "serious", "ready", "simple", "left",
            "physical", "common", "economic", "current", "likely", "natural",
            "significant", "similar", "hot", "dead", "central", "happy",
            "financial", "wide", "dark", "heavy", "single", "final", "main",
            "present", "close", "legal", "various", "medical", "national",
            "traditional", "potential", "basic", "positive", "necessary",
            "critical", "deep", "entire", "individual", "nice", "cold",
            "professional", "poor", "private", "direct", "additional",
            "normal", "effective", "successful", "rich", "popular",
            "complete", "military", "standard", "wrong", "safe", "pretty",
            "modern", "key", "environmental", "specific", "fair",
            "previous", "total", "actual", "average", "cultural", "primary",
            "independent", "original", "appropriate", "digital", "technical",

            // Common adverbs
            "very", "really", "too", "still", "already", "always", "never", "often",
            "sometimes", "usually", "probably", "actually", "quickly", "almost",
            "enough", "early", "especially", "ever", "certainly", "perhaps",
            "simply", "quite", "finally", "rather", "recently", "exactly",
            "directly", "likely", "immediately", "slowly", "clearly", "obviously",
            "apparently", "generally", "essentially", "carefully", "easily",
            "necessarily", "significantly", "normally", "currently", "highly",
            "eventually", "basically", "particularly", "hardly", "largely",
            "slightly", "previously", "typically", "relatively", "specifically",
            "merely", "increasingly", "potentially", "frequently", "entirely",
            "relatively", "truly", "mostly", "roughly", "primarily",

            // More common words (nouns, verbs, adjectives mixed)
            "ability", "able", "about", "above", "accept", "according", "account", "across",
            "act", "action", "activity", "actually", "address", "administration", "admit",
            "adult", "affect", "again", "against", "agency", "agent", "ago", "agree",
            "agreement", "ahead", "allow", "almost", "alone", "along", "already", "also",
            "always", "american", "among", "amount", "analysis", "animal", "another",
            "answer", "anyone", "anything", "anyway", "apart", "apparently", "apply",
            "approach", "argue", "argument", "arm", "army", "around", "arrive", "article",
            "artist", "assume", "attack", "attention", "audience", "author", "authority",
            "avoid", "away", "baby", "bag", "ball", "bank", "bar", "base", "beat",
            "beautiful", "bed", "before", "behavior", "behind", "believe", "benefit",
            "beyond", "bill", "billion", "bit", "black", "blood", "blue", "board",
            "born", "both", "box", "boy", "break", "bring", "brother", "brown",
            "budget", "building", "buy", "call", "camera", "campaign", "cancer",
            "candidate", "capital", "card", "care", "career", "carry", "catch",
            "cause", "cell", "center", "century", "chair", "challenge", "chance",
            "character", "charge", "check", "choice", "choose", "church", "citizen",
            "civil", "claim", "clearly", "close", "coach", "cold", "collection",
            "college", "color", "come", "commercial", "common", "community",
            "compare", "computer", "concern", "condition", "conference", "congress",
            "connection", "consider", "consumer", "contain", "control", "conversation",
            "cost", "could", "country", "couple", "cover", "crime", "cultural",
            "culture", "cup", "customer", "dark", "data", "daughter", "deal", "death",
            "debate", "decade", "decision", "deep", "defense", "degree", "democrat",
            "department", "depend", "describe", "design", "despite", "detail",
            "determine", "different", "difficult", "dinner", "direction", "director",
            "discover", "discussion", "disease", "doctor", "dog", "door", "down",
            "draw", "dream", "drive", "drop", "drug", "during", "each", "east",
            "economic", "economy", "edge", "education", "eight", "either", "election",
            "else", "employee", "energy", "enjoy", "enough", "enter", "environment",
            "especially", "establish", "even", "evening", "event", "every", "everybody",
            "everyone", "everything", "evidence", "exactly", "example", "executive",
            "exist", "experience", "expert", "explain", "eye", "face", "fact", "factor",
            "fail", "family", "far", "fast", "father", "fear", "federal", "feel",
            "figure", "fill", "film", "final", "financial", "find", "fine", "finger",
            "finish", "fire", "firm", "fish", "five", "floor", "fly", "focus",
            "follow", "foot", "force", "foreign", "forget", "former", "forward",
            "four", "free", "front", "full", "fund", "future", "garden", "gas",
            "generation", "girl", "give", "glass", "goal", "good", "government",
            "great", "green", "ground", "group", "grow", "growth", "guess", "gun",
            "guy", "hair", "half", "hang", "happen", "happy", "hard", "have",
            "head", "health", "hear", "heart", "heat", "heavy", "help", "here",
            "herself", "high", "himself", "hit", "hold", "hope", "hospital",
            "hotel", "house", "how", "however", "huge", "hundred", "husband",

            // I-L continued
            "identify", "image", "imagine", "impact", "implement", "important",
            "improve", "indeed", "indicate", "individual", "industry", "inside",
            "instead", "institution", "interest", "interview", "investment", "involve",
            "item", "itself", "join", "just", "keep", "key", "kid", "kind", "kitchen",
            "knowledge", "language", "large", "later", "laugh", "lawyer", "lay",
            "leader", "least", "leave", "leg", "less", "letter", "level", "lie",
            "light", "likely", "limit", "listen", "little", "local", "long",
            "loss", "lot",

            // M-N
            "machine", "magazine", "maintain", "majority", "manage", "management",
            "manager", "many", "material", "may", "maybe", "mean", "measure",
            "media", "medical", "meeting", "memory", "mention", "message", "method",
            "middle", "might", "military", "million", "mind", "minute", "miss",
            "mission", "model", "modern", "moment", "more", "morning", "most",
            "mouth", "move", "movement", "movie", "much", "must", "myself",
            "nation", "national", "natural", "nature", "near", "nearly",
            "necessary", "network", "news", "newspaper", "nice", "none",
            "north", "note", "nothing", "notice", "now", "number",

            // O-P
            "occur", "official", "often", "oil", "once", "only", "onto",
            "operation", "opportunity", "option", "order", "organization",
            "others", "otherwise", "our", "outside", "own", "owner",
            "page", "pain", "painting", "pair", "paper", "parent", "partner",
            "party", "patient", "pattern", "peace", "per", "perform",
            "performance", "period", "permit", "personal", "phone", "pick",
            "picture", "piece", "place", "plan", "plant", "player",
            "please", "point", "policy", "political", "politics", "poor",
            "popular", "population", "position", "positive", "possible",
            "practice", "prepare", "pressure", "pretty", "prevent",
            "price", "private", "probably", "problem", "produce", "product",
            "production", "professional", "professor", "property", "protect",
            "prove", "public", "purpose", "push", "put", "quality",

            // R-S
            "race", "raise", "range", "rather", "reach", "ready",
            "reality", "realize", "reason", "receive", "recognize",
            "record", "reduce", "reflect", "region", "relate", "relationship",
            "religious", "remove", "repeat", "replace", "represent",
            "republican", "require", "resource", "respond", "response",
            "rest", "result", "return", "reveal", "right", "rise", "risk",
            "road", "rock", "role", "rule", "safe", "scene", "science",
            "scientist", "score", "sea", "season", "seat", "second",
            "section", "security", "seek", "seem", "sense", "series",
            "serve", "set", "seven", "several", "shake", "shall", "shape",
            "share", "she", "shoot", "short", "shot", "should", "shoulder",
            "show", "significant", "sign", "since", "sing", "sister", "sit",
            "site", "situation", "six", "size", "skill", "skin", "smile",
            "society", "soldier", "some", "somebody", "someone", "something",
            "sometimes", "son", "song", "soon", "sort", "sound", "source",
            "south", "southern", "space", "speak", "specific", "speech",
            "spend", "sport", "spring", "staff", "stage", "standard",
            "star", "start", "statement", "station", "step", "stock",
            "stop", "store", "strategy", "structure", "student", "stuff",
            "style", "subject", "success", "such", "suddenly", "suffer",
            "summer", "surface", "system",

            // T-Z
            "take", "talk", "task", "tax", "teach", "technology", "television",
            "ten", "tend", "term", "test", "than", "thank", "themselves",
            "theory", "these", "they", "thing", "third", "those", "though",
            "thought", "thousand", "threat", "three", "through", "throughout",
            "throw", "thus", "today", "together", "tonight", "top", "total",
            "tough", "toward", "towards", "town", "trade", "training",
            "travel", "treat", "treatment", "tree", "trial", "trip", "trouble",
            "truth", "try", "turn", "tv", "twelve", "twenty", "type",
            "under", "unit", "until", "upon", "us", "usually",
            "value", "various", "very", "victim", "violence", "visit", "voice",
            "vote", "wait", "wall", "want", "watch", "weapon",
            "wear", "weight", "well", "west", "western", "whatever",
            "whether", "while", "whom", "whose", "why", "wide",
            "wife", "window", "wish", "within", "without", "wonder",
            "worker", "working", "worry", "would", "wrong",
            "yard", "yeah", "yes", "yet", "young", "yourself",

            // Additional common words to reach ~2500
            "above", "absolute", "academic", "access", "accident", "accomplish",
            "accurate", "achieve", "achievement", "acknowledge", "acquire", "actual",
            "adapt", "adequate", "adjust", "advance", "advanced", "advantage",
            "advertise", "advice", "advise", "affair", "afford", "afraid", "afternoon",
            "age", "ahead", "aid", "aim", "airport", "alive", "alleged", "alliance",
            "alongside", "alternative", "amazing", "amendment", "analyze",
            "ancient", "anger", "angle", "angry", "announce", "annual",
            "anticipate", "anxiety", "apart", "apartment", "appeal", "apparent",
            "appreciate", "approval", "approve", "approximately", "arrange",
            "arrangement", "arrest", "arrival", "aside", "aspect", "assault",
            "assert", "assess", "assessment", "asset", "assign", "assist",
            "assistance", "associate", "association", "assumption", "atmosphere",
            "attach", "attempt", "attend", "attract", "attractive", "attribute",
            "aunt", "automatic", "automobile", "aware", "awful",

            "background", "balance", "band", "baseball", "basic", "basis",
            "basket", "basketball", "bathroom", "battery", "battle", "beach",
            "bear", "beauty", "bedroom", "beer", "beginning", "beneath",
            "beside", "bet", "bible", "bind", "biological", "bird", "birth",
            "bite", "blade", "blame", "blank", "blast", "blend", "bless",
            "blind", "block", "blow", "boat", "bond", "bone", "bonus",
            "border", "bother", "bottom", "bound", "bowl", "brain", "brand",
            "brave", "bread", "breakfast", "breath", "breathe", "brick",
            "bridge", "brief", "bright", "brilliant", "broad", "broke",
            "broken", "brush", "buck", "bulk", "bullet", "bunch", "burden",
            "burn", "bus", "busy", "button",

            "cabin", "cabinet", "cable", "cake", "calculate", "calm",
            "camp", "campus", "capable", "capacity", "capture", "carbon",
            "careful", "carrier", "category", "celebrate", "celebration",
            "chain", "championship", "chapter", "characteristic", "cheap",
            "chemical", "chief", "childhood", "chip", "chocolate", "chose",
            "chosen", "chronic", "chunk", "cigarette", "circle", "circumstance",
            "cite", "civilian", "classic", "classroom", "clean", "client",
            "climate", "climb", "clinical", "clock", "closely", "closer",
            "clothes", "clothing", "cloud", "club", "clue", "cluster",
            "coalition", "coast", "code", "cognitive", "collapse", "colleague",
            "combat", "combination", "combine", "comfortable", "command",
            "comment", "commission", "commit", "commitment", "committee",
            "communicate", "communication", "companion", "comparison", "compete",
            "competition", "competitive", "complain", "complaint", "complex",
            "complexity", "component", "comprehensive", "concentrate",
            "concept", "conclude", "conclusion", "concrete", "conduct",
            "confidence", "confident", "confirm", "conflict", "confront",
            "confusion", "congressional", "connect", "consciousness",
            "consensus", "consequence", "conservative", "considerable",
            "consistent", "constant", "constitutional", "construct",
            "construction", "consultant", "consumption", "contact",
            "contemporary", "content", "context", "contract", "contrast",
            "contribute", "contribution", "controversial", "controversy",
            "convention", "conventional", "convince", "cook", "cool",
            "cooperation", "cope", "copy", "core", "corner", "corporate",
            "correct", "correspond", "correspondent", "cotton", "couch",
            "council", "count", "counter", "county", "courage", "court",
            "cousin", "coverage", "crack", "craft", "crash", "crazy",
            "creative", "creature", "credit", "crew", "criminal", "crisis",
            "criteria", "critic", "criticism", "criticize", "crop", "cross",
            "crowd", "crucial", "cry", "cure", "curious", "current",
            "curriculum", "custom", "cycle",

            "daily", "damage", "dance", "danger", "dangerous", "dare",
            "database", "deadline", "dear", "deeply", "deer", "defeat",
            "defendant", "defensive", "deficit", "define", "definitely",
            "definition", "deliver", "delivery", "demand", "demonstrate",
            "deny", "depart", "departure", "dependent", "deploy", "depression",
            "derive", "desert", "deserve", "designer", "desire", "desk",
            "desperate", "destroy", "destruction", "detect", "developer",
            "device", "devote", "dialogue", "diet", "digital", "dimension",
            "diplomatic", "dirt", "dirty", "disability", "disagree",
            "disappear", "disaster", "discipline", "discourse", "discrimination",
            "dismiss", "disorder", "display", "dispute", "distance",
            "distinct", "distinction", "distinguish", "distribute",
            "distribution", "district", "disturb", "diverse", "diversity",
            "divide", "division", "document", "dollar", "domestic",
            "dominant", "dominate", "double", "doubt", "downtown", "dozen",
            "draft", "drag", "drama", "dramatic", "dramatically", "draw",
            "drift", "drink", "driver", "dry", "due", "dump", "dust",
            "duty", "dynamic",

            "eager", "earn", "earnings", "ease", "eastern", "eat", "editor",
            "educational", "effectively", "efficiency", "efficient", "effort",
            "elderly", "elect", "electrical", "electronic", "element",
            "eliminate", "elite", "embrace", "emerge", "emergency", "emission",
            "emotion", "emotional", "emphasis", "emphasize", "empire",
            "employ", "employer", "employment", "empty", "enable",
            "encounter", "encourage", "engineering", "enormous", "ensure",
            "enterprise", "entertainment", "enthusiasm", "entrance",
            "entry", "episode", "equal", "equally", "equipment", "era",
            "error", "escape", "essay", "essentially", "estate",
            "estimate", "ethics", "evaluate", "evaluation", "evolve",
            "examine", "exceed", "excellent", "exception", "exchange",
            "exciting", "exclude", "exercise", "exhibit", "exhibition",
            "expand", "expansion", "expense", "experiment", "experimental",
            "explanation", "explicit", "exploit", "exploration", "explore",
            "explosion", "export", "expose", "exposure", "expression",
            "extend", "extension", "extensive", "extent", "external",
            "extra", "extraordinary", "extreme", "extremely",

            "fabric", "facilitate", "facility", "failure", "faith",
            "false", "familiar", "fan", "fantasy", "farmer", "fashion",
            "fate", "fault", "favor", "favorite", "feature", "fee", "feed",
            "fellow", "female", "fence", "festival", "fewer", "fiction",
            "fifteen", "fifth", "fifty", "fight", "fighter", "file",
            "finding", "fine", "flag", "flame", "flat", "flavor", "flee",
            "flesh", "flight", "float", "flood", "flow", "flower",
            "folk", "football", "forecast", "forehead", "forever",
            "formation", "formula", "forth", "fortune", "forty",
            "foundation", "founder", "fourth", "fraction", "frame",
            "framework", "freeze", "frequent", "frequently", "fresh",
            "friendship", "frighten", "fruit", "fuel", "fulfill",
            "function", "fundamental", "funding", "furniture",

            "gain", "gallery", "gap", "garage", "gate", "gather",
            "gay", "gaze", "gear", "gender", "gene", "genetic",
            "gentle", "gentleman", "genuine", "gesture", "giant",
            "gift", "glad", "glance", "global", "glory", "golf", "grab",
            "grace", "grade", "gradually", "graduate", "grain", "grand",
            "grandfather", "grandmother", "grant", "grass", "grateful",
            "grave", "gray", "grey", "greatly", "grocery", "gross",
            "guarantee", "guard", "guidance", "guide", "guilty",

            "habit", "handle", "harbor", "hardly", "harmful", "hat",
            "hate", "headline", "headquarters", "healthy", "hearing",
            "heaven", "heavily", "hell", "helpful", "hence", "hero",
            "hide", "highlight", "highway", "hill", "hint", "hire",
            "historic", "historical", "hole", "holiday", "holy", "honest",
            "honor", "hook", "horizon", "horrible", "host", "hostile",
            "household", "housing", "hunt", "hurt", "hypothesis",

            "ice", "ideal", "identical", "identity", "ideology",
            "ignore", "ill", "illegal", "illness", "illustrate",
            "illustration", "immediately", "immigrant", "immigration",
            "immune", "implication", "imply", "import", "impose",
            "impossible", "impression", "impressive", "incident",
            "incorporate", "increase", "increasingly", "incredible",
            "incredibly", "independence", "index", "indian",
            "indication", "inevitable", "infant", "infection", "inflation",
            "influence", "inform", "initial", "initially", "initiative",
            "injury", "inner", "innocent", "innovation", "innovative",
            "input", "inquiry", "insect", "insert", "insight",
            "insist", "inspection", "inspector", "inspiration", "inspire",
            "install", "instance", "instant", "institutional",
            "instruction", "instrument", "insurance", "intellectual",
            "intelligence", "intelligent", "intend", "intense", "intensity",
            "intention", "interact", "interaction", "interesting",
            "internal", "interpretation", "intervention", "introduction",
            "invasion", "investigate", "investigation", "investigator",
            "investor", "invisible", "invitation", "invite", "iron",
            "islamic", "island", "isolate", "isolation", "issue",

            "jacket", "jail", "joint", "joke", "journal", "journalist",
            "journey", "joy", "judge", "judgment", "juice", "jump",
            "junior", "jury", "justice", "justify",

            "keen", "kiss", "knee", "knife", "knock",

            "label", "labor", "lack", "lady", "lake", "landscape",
            "lane", "lap", "largely", "launch", "lawn", "lawsuit",
            "layer", "leadership", "league", "lean", "lecture", "left",
            "legacy", "legend", "legislation", "legitimate", "leisure",
            "length", "lesson", "liberal", "liberty", "library",
            "license", "lift", "likewise", "limitation", "link",
            "lip", "list", "literary", "literature", "load", "loan",
            "lobby", "lock", "log", "logic", "lonely", "loose",
            "lord", "lovely", "lover", "luck", "lucky", "lunch", "lung",

            "mad", "magic", "magnetic", "magnificent", "mainly",
            "maker", "male", "mall", "manner", "manufacturer",
            "manufacturing", "map", "margin", "mark", "marry",
            "mask", "mass", "massive", "master", "match", "mate",
            "meal", "meaning", "meanwhile", "mechanism", "medium",
            "membership", "mental", "merely", "merge", "mess", "metal",
            "meter", "midnight", "mild", "mine", "minimum", "minister",
            "minor", "minority", "miracle", "mirror", "missing",
            "mistake", "mix", "mixture", "mobile", "moderate",
            "modification", "modify", "mom", "monitor", "mood", "moon",
            "moral", "moreover", "mortgage", "mount", "mountain", "mouse",
            "multiple", "murder", "muscle", "museum", "mutual", "mystery",
            "myth",

            "nail", "naked", "narrow", "nasty", "negotiate",
            "negotiation", "neighbor", "neighborhood", "neither", "nerve",
            "nevertheless", "newly", "nightmare", "noble", "nod", "noise",
            "nomination", "nonetheless", "nonsense", "noon", "nor",
            "northeast", "nose", "notable", "novel", "nowhere", "nuclear",
            "numerous", "nurse", "nut",

            "object", "objection", "objective", "obligation", "observation",
            "observe", "observer", "obstacle", "obtain", "obvious",
            "obviously", "occasion", "occasionally", "occupation", "occupy",
            "odd", "odds", "offense", "offensive", "olympic", "ongoing",
            "opponent", "oppose", "opposite", "opposition", "organic",
            "orientation", "origin", "other", "otherwise", "ought",
            "outcome", "outdoor", "output", "overall", "overcome",
            "overlook", "overnight", "overseas", "owe", "ownership",

            "pace", "pack", "package", "pale", "palm", "pan", "panel",
            "panic", "paragraph", "parallel", "park", "parking",
            "participation", "partly", "passage", "passenger", "passion",
            "passive", "path", "pause", "peak", "peer", "penalty",
            "pension", "percent", "percentage", "perception", "perfect",
            "perfectly", "permanent", "permission", "personality",
            "perspective", "phase", "phenomenon", "philosophy",
            "photograph", "photography", "phrase", "physician", "pile",
            "pilot", "pine", "pink", "pipe", "pitch", "platform",
            "pleasure", "plenty", "plot", "plus", "pocket", "poem",
            "poet", "poetry", "poll", "pollution", "pool", "pop",
            "portrait", "portray", "pose", "possession", "poverty",
            "powder", "powerful", "practically", "pray", "prayer",
            "precisely", "predict", "prediction", "preference", "pregnancy",
            "prejudice", "premier", "premise", "premium", "preparation",
            "presence", "presentation", "preserve", "presidency",
            "presidential", "presumably", "pretend", "primarily",
            "prime", "principal", "principle", "print", "prior",
            "priority", "prison", "prisoner", "privacy", "prize",
            "proceed", "proceeding", "processor", "profile", "profit",
            "profound", "progressive", "project", "prominent", "promise",
            "promote", "promotion", "prompt", "proof", "proper",
            "properly", "proportion", "proposal", "propose", "proposed",
            "prosecutor", "prospect", "protection", "protein", "protest",
            "proud", "provision", "provoke", "psychiatric", "psychological",
            "psychologist", "psychology", "pub", "publication", "publish",
            "punishment", "purchase", "pure", "pursue", "pursuit",

            "qualify", "quick", "quickly", "quiet", "quietly", "quit", "quote",

            "racial", "racism", "radical", "rain", "rally", "random",
            "rank", "rapid", "rapidly", "rare", "rarely", "raw",
            "reaction", "reader", "reading", "realistic", "reasonable",
            "recall", "recovery", "recruit", "reduction", "refer",
            "reference", "reflection", "reform", "refugee", "refuse",
            "regard", "regime", "regional", "register", "regulate",
            "regulation", "reinforce", "reject", "relate", "related",
            "relative", "relatively", "relax", "release", "relevant",
            "relief", "religion", "rely", "remarkable", "remedy",
            "reminder", "remote", "removal", "render", "rent", "repair",
            "repeatedly", "replacement", "reporter", "representation",
            "reputation", "request", "requirement", "resident",
            "residential", "resign", "resist", "resistance", "resolution",
            "resolve", "resort", "respective", "responsibility",
            "responsible", "restaurant", "restoration", "restore",
            "restriction", "retain", "retire", "retirement", "retreat",
            "revenue", "reverse", "review", "revolution", "reward",
            "rhetoric", "rhythm", "ride", "rifle", "ring", "riot",
            "rival", "romantic", "roof", "root", "rope", "rose",
            "rotate", "rough", "round", "routine", "row", "royal",
            "ruin", "ruling", "rural", "rush",

            "sacred", "sacrifice", "sad", "sadly", "salary", "salt",
            "sample", "sanction", "sand", "satellite", "satisfaction",
            "satisfy", "sauce", "save", "scale", "scandal", "scare",
            "scenario", "schedule", "scholar", "scholarship", "scope",
            "scream", "screen", "script", "search", "secondary",
            "secret", "secretary", "sector", "secure", "seed",
            "segment", "select", "selection", "self", "senate",
            "senator", "senior", "sensitive", "sentence", "separate",
            "sequence", "seriously", "session", "settle", "settlement",
            "severe", "sexual", "shadow", "shallow", "shame",
            "sharp", "sheer", "sheet", "shelf", "shell", "shelter",
            "shift", "shine", "ship", "shock", "shopping", "shore",
            "shortage", "shut", "sick", "sight", "signal",
            "silence", "silent", "silly", "silver", "similarly",
            "sin", "sir", "situation", "sixty", "skeptic", "slave",
            "slavery", "sleep", "slice", "slide", "slight",
            "slip", "smart", "smell", "snap", "snow", "so",
            "soccer", "soft", "software", "soil", "solar", "sole",
            "solely", "solid", "solution", "solve", "somewhat",
            "sophisticated", "soul", "southeast", "southwest", "span",
            "spare", "specialist", "species", "spectacular", "spectrum",
            "spirit", "spiritual", "spokesman", "sponsor", "spot",
            "spray", "spread", "squad", "stability", "stable",
            "stadium", "stake", "stare", "startup", "statistics",
            "status", "statute", "steady", "steal", "steam", "steel",
            "steep", "stem", "stereotype", "stick", "stiff", "stimulus",
            "stomach", "storage", "storm", "straight", "strain",
            "strange", "stranger", "strategic", "stream", "strength",
            "strengthen", "stress", "stretch", "strict", "strike",
            "strip", "stroke", "strongly", "struggle", "studio",
            "stupid", "subsequent", "substance", "substantial",
            "succeed", "sue", "sufficient", "sugar", "suicide",
            "suit", "suitable", "sum", "summit", "super", "supply",
            "supposed", "supposedly", "supreme", "sure", "surely",
            "surgery", "surplus", "surprise", "surprising", "surprisingly",
            "surround", "surrounding", "survey", "survival", "survive",
            "survivor", "suspect", "suspend", "suspicion", "sustain",
            "swallow", "swear", "sweet", "swim", "swing", "switch",
            "symbol", "sympathy", "syndrome", "systematic",

            "tackle", "tail", "talent", "tank", "tap", "tape",
            "target", "taxpayer", "tea", "teammate", "tear",
            "teenage", "telephone", "temple", "temporary", "tenant",
            "tendency", "tender", "tennis", "tension", "terrible",
            "territory", "terror", "terrorism", "terrorist", "testimony",
            "testing", "text", "texture", "theme", "therapy", "thereby",
            "thick", "thin", "thoroughly", "thread", "throat", "tie",
            "tight", "till", "timber", "tiny", "tip", "tire", "tired",
            "tissue", "title", "tobacco", "toe", "tolerance", "tone",
            "tongue", "tool", "topic", "tort", "torture", "toss",
            "touch", "tourism", "tourist", "tournament", "tower",
            "track", "tradition", "traffic", "tragedy", "trail",
            "train", "trait", "transaction", "transfer", "transform",
            "transformation", "transition", "translate", "transmission",
            "transport", "transportation", "trap", "trash", "tremendous",
            "trend", "tribe", "trick", "trigger", "troop", "tropical",
            "truck", "truly", "trust", "tube", "tuck", "tunnel",
            "twice", "twin", "twist", "typical", "typically",

            "ugly", "ultimate", "ultimately", "unable", "uncle",
            "undergo", "underlying", "understand", "understanding",
            "unemployment", "unfair", "unfortunately", "unhappy",
            "uniform", "unify", "unique", "universe", "university",
            "unknown", "unless", "unlikely", "unusual", "update",
            "upper", "upset", "urban", "urge", "usage", "useful",
            "user", "usual", "utility",

            "vacation", "valley", "valuable", "van", "variation",
            "variety", "vast", "vehicle", "venture", "version",
            "versus", "veteran", "via", "vice", "viewer", "violate",
            "violation", "virtue", "visible", "vision", "visual",
            "vital", "vocabulary", "volume", "voluntary", "volunteer",
            "vulnerable",

            "wage", "wake", "warm", "warn", "warning", "wash",
            "waste", "wave", "weakness", "wealth", "wealthy",
            "web", "website", "wedding", "weekend", "weekly",
            "welcome", "welfare", "wheel", "whenever", "whereas",
            "wherever", "whisper", "wild", "willing", "wind",
            "wine", "wing", "winter", "wire", "wisdom", "wise",
            "withdraw", "witness", "wood", "wooden", "worth",
            "wrap", "writing",

            "zone",

            // Common function words and short words often seen in text
            "am", "are", "is", "was", "were", "been", "being",
            "has", "had", "having", "does", "did", "doing",
            "shall", "may", "might", "must", "ought",
            "here", "there", "where", "when", "why", "how",
            "each", "every", "both", "few", "more", "many", "much",
            "such", "own", "same", "other", "another", "enough",
            "off", "down", "between", "through", "during", "before",
            "after", "above", "below", "against", "upon", "under",
            "within", "without", "along", "among", "around", "behind",
            "beside", "beyond", "inside", "outside", "toward", "towards",
            "across", "until", "since", "per", "via", "plus", "versus",
            "nor", "yet", "either", "neither", "whether",
            "not", "never", "always", "often", "sometimes", "usually",
            "perhaps", "maybe", "quite", "rather", "very", "too",
            "also", "just", "only", "still", "already", "even",
            "again", "further", "then", "once",

            // Contractions (without apostrophe, as tokenizer may strip them)
            "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent",
            "hasnt", "havent", "hadnt", "wont", "wouldnt", "shouldnt",
            "couldnt", "cant", "mustnt", "neednt", "shant",
            "thats", "whats", "whos", "hows", "wheres", "whens", "whys",
            "its", "lets", "hes", "shes", "theyre", "were", "youre",
            "ive", "youve", "weve", "theyve", "hed", "shed", "theyd",
            "wed", "youd", "ill", "youll", "hell", "shell", "theyll", "well",

            // Numbers as words
            "zero", "three", "four", "five", "six", "seven", "eight",
            "nine", "eleven", "thirteen", "fourteen", "sixteen",
            "seventeen", "eighteen", "nineteen", "thirty", "forty",
            "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
            "million", "billion", "trillion",

            // Common academic / formal words
            "abstract", "accordingly", "accumulate", "accuracy",
            "allegation", "allocate", "alter", "ambiguity", "amid",
            "analogy", "arbitrary", "array", "articulate",
            "assemble", "assertion", "behalf", "bias", "bind",
            "brief", "broadly", "bureaucracy", "capability",
            "caption", "catalog", "cease", "channel",
            "civic", "clarity", "clause", "cluster", "coexist",
            "coherent", "coincide", "colleague", "commentary",
            "commodity", "communal", "compatibility", "compensate",
            "compensation", "compilation", "complement", "compliance",
            "comply", "comprise", "compulsory", "conceive",
            "concurrent", "confine", "configuration", "conform",
            "consolidate", "constitute", "constrain", "constraint",
            "consult", "contemplate", "contend", "contradict",
            "contrary", "conversion", "convert", "convey",
            "coordinate", "correlation", "counterpart",
            "cumulative", "currency", "custody",

            "decisive", "declaration", "decline", "dedicate",
            "deem", "default", "deficiency", "delegate",
            "deliberate", "denote", "depict", "deplete",
            "designate", "destine", "deteriorate", "deviate",
            "diagram", "diminish", "discrete", "displace",
            "dispose", "disproportionate", "disrupt", "dissolve",
            "distort", "domain", "dominant", "draft",
            "duration", "dwell",

            "elaborate", "embed", "empirical", "encompass",
            "endorse", "enforce", "enhancement", "entity",
            "enumerate", "equip", "equivalent", "erode",
            "eventual", "evolve", "excerpt", "exclusive",
            "exempt", "exert", "exhibit", "explicit",
            "exploit", "extract",

            "feasible", "finite", "fluctuate", "formulate",
            "forthcoming", "foster", "fragment", "friction",
            "frontier",

            "generic", "globe", "goodwill", "governance",
            "gradient", "graph", "grave", "guideline",

            "halt", "hamper", "harsh", "hazard", "heighten",
            "hierarchy", "hinder", "hostile",

            "identical", "illuminate", "immense", "imperative",
            "implicit", "incidence", "incline", "incompatible",
            "incorporate", "increment", "indefinite", "indigenous",
            "induce", "inequality", "inevitable", "infrastructure",
            "inherent", "inhibit", "initiate", "inject",
            "integral", "integrate", "integrity", "interface",
            "interim", "intermediate", "interval", "intervene",
            "intrinsic", "invoke", "irrelevant", "iterate",

            "jurisdiction", "justification",

            "lag", "layout", "leverage", "liable", "likewise",
            "linear", "literally", "log", "logical",

            "magnitude", "mandate", "manifest", "manipulate",
            "manual", "manuscript", "marginal", "mature",
            "maximize", "mediate", "methodology", "migrate",
            "minimal", "minimize", "ministry", "mode",
            "module", "momentum",

            "negate", "neutral", "nominal", "norm",
            "normalize", "notable", "notify", "notion",
            "notwithstanding",

            "offset", "ongoing", "optimal", "orient",
            "outline", "overlap", "oversee", "overview",

            "paradigm", "parameter", "partial", "participate",
            "partition", "peer", "perceive", "persist",
            "pioneer", "placement", "plausible", "polarize",
            "portion", "preach", "precede", "precedent",
            "precise", "predominant", "preliminary", "prescribe",
            "prevail", "prevalent", "principal", "probe",
            "procurement", "prohibit", "projection", "proliferate",
            "propagate", "prone", "proportional", "protocol",
            "proviso", "proxy",

            "quota",

            "rationale", "realm", "reconcile", "redundant",
            "refine", "regime", "reinstate", "reiterate",
            "reliance", "reluctant", "remainder", "replicate",
            "repository", "repression", "residual", "respective",
            "restrain", "retain", "retrieve", "retrospect",
            "rigid", "robust", "roster",

            "safeguard", "sake", "scrutiny", "secular",
            "seminar", "simulate", "simultaneous", "skeleton",
            "sole", "solidarity", "specification", "speculate",
            "sphere", "stance", "stark", "stationary",
            "stipulate", "straightforward", "strand", "subjective",
            "subordinate", "subscribe", "subsidiary", "subsidy",
            "substitute", "successive", "supplement", "suppress",
            "surge", "surveillance", "susceptible", "suspend",
            "sustain", "synthetic",

            "tangible", "terminate", "textbook", "thereafter",
            "threshold", "tolerance", "trajectory", "transmit",
            "transparent", "trauma",

            "unanimous", "undergo", "undermine", "undertake",
            "undue", "unfold", "unify", "unprecedented",
            "uphold", "utilize",

            "validate", "variable", "verify", "viable",
            "violate", "virtual", "vocal",

            "warrant", "widespread", "workforce",

            "yield",
        ]
    }()
}
