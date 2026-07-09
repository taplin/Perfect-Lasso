import Foundation

struct Finding: Hashable, Comparable {
    let key: String
    let file: String
    let line: Int
    let excerpt: String

    static func < (lhs: Finding, rhs: Finding) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        if lhs.file != rhs.file { return lhs.file < rhs.file }
        return lhs.line < rhs.line
    }
}

struct CodeSpan {
    enum Delimiter: String {
        case square = "square_bracket"
        case lasso = "php_lasso"
        case echo = "php_echo"
    }

    let delimiter: Delimiter
    let startOffset: String.Index
    let text: String
}

struct Counter {
    private(set) var counts: [String: Int] = [:]
    private(set) var examples: [String: Set<Finding>] = [:]

    mutating func add(_ key: String, file: String, line: Int, excerpt: String) {
        counts[key, default: 0] += 1
        var set = examples[key, default: []]
        if set.count < 8 {
            set.insert(Finding(key: key, file: file, line: line, excerpt: excerpt))
        }
        examples[key] = set
    }

    func sortedCounts() -> [(String, Int)] {
        counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
    }
}

struct ScanResult {
    var files = 0
    var bytes = 0
    var delimiterCounts: [String: Int] = [:]
    var constructs = Counter()
    var inlineParams = Counter()
    var memberCalls = Counter()
    var functionCalls = Counter()
    var customCandidates = Counter()
    var extensions: [String: Int] = [:]
}

struct Scanner {
    let root: URL
    let rootPath: String
    let excludes: [String]
    let allowedExtensions = Set(["lasso", "inc", "ldml", "htm", "html"])
    let knownCalls = Set([
        "abort", "action_param", "array", "boolean", "capture", "column", "date",
        "decimal", "define", "email_send", "encode_html", "encode_sql", "encode_url",
        "field", "found_count", "if", "include", "inline", "integer", "iterate",
        "json_serialize", "local", "loop", "map", "match", "math_abs", "pair",
        "params", "protect", "records", "redirect_url", "rows", "string", "var",
        "while", "with"
    ])

    func run() throws -> ScanResult {
        var result = ScanResult()
        let files = lassoFiles()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            guard isLassoSource(text, extension: file.pathExtension.lowercased()) else {
                continue
            }
            result.files += 1
            result.bytes += text.utf8.count
            result.extensions[file.pathExtension.lowercased(), default: 0] += 1
            let relative = relativePath(file)
            let spans = extractCodeSpans(from: text)
            for span in spans {
                result.delimiterCounts[span.delimiter.rawValue, default: 0] += 1
                analyze(span: span, fullText: text, file: relative, result: &result)
            }
        }
        return result
    }

    private func isLassoSource(_ text: String, extension fileExtension: String) -> Bool {
        guard fileExtension == "htm" || fileExtension == "html" else { return true }
        let lower = text.lowercased()
        let markers = [
            "<?lasso", "[inline", "[records", "[rows", "[if", "[var", "[local",
            "[include", "[define", "[protect", "[iterate", "[loop", "[while",
            "[no_square_brackets"
        ]
        return markers.contains(where: lower.contains)
    }

    private func lassoFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let path = url.path
            guard !excludes.contains(where: { path.contains($0) }) else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func extractCodeSpans(from text: String) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        var index = text.startIndex
        var squareBracketsEnabled = true

        while index < text.endIndex {
            if text[index...].caseInsensitiveHasPrefix("<?lasso") {
                let codeStart = text.index(index, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex
                let end = text[codeStart...].range(of: "?>")?.lowerBound ?? text.endIndex
                spans.append(CodeSpan(delimiter: .lasso, startOffset: codeStart, text: String(text[codeStart..<end])))
                index = end < text.endIndex ? text.index(end, offsetBy: 2) : text.endIndex
                continue
            }

            if text[index...].hasPrefix("<?=") {
                let codeStart = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                let end = text[codeStart...].range(of: "?>")?.lowerBound ?? text.endIndex
                spans.append(CodeSpan(delimiter: .echo, startOffset: codeStart, text: String(text[codeStart..<end])))
                index = end < text.endIndex ? text.index(end, offsetBy: 2) : text.endIndex
                continue
            }

            if squareBracketsEnabled, text[index] == "[" {
                let codeStart = text.index(after: index)
                if let end = findSquareClose(in: text, from: codeStart) {
                    let code = String(text[codeStart..<end])
                    if code.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("no_square_brackets") == .orderedSame {
                        squareBracketsEnabled = false
                    }
                    spans.append(CodeSpan(delimiter: .square, startOffset: codeStart, text: code))
                    index = text.index(after: end)
                    continue
                }
            }

            index = text.index(after: index)
        }

        return spans
    }

    private func findSquareClose(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        var quote: Character?
        while index < text.endIndex {
            let ch = text[index]
            if let active = quote {
                if ch == active {
                    quote = nil
                }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "]" {
                return index
            } else if ch == "\n", text.distance(from: start, to: index) > 600 {
                return nil
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func analyze(span: CodeSpan, fullText: String, file: String, result: inout ScanResult) {
        let line = lineNumber(in: fullText, at: span.startOffset)
        let normalized = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = normalized.singleLineExcerpt()
        let lower = normalized.lowercased()

        let constructPatterns: [(String, String)] = [
            ("inline", #"(?i)\binline\s*(?:\(|:)"#),
            ("records", #"(?i)(^|\s)records\b|\[\s*records\s*\]"#),
            ("rows", #"(?i)(^|\s)rows\b|\[\s*rows\s*\]"#),
            ("if", #"(?i)(^|\s)/?if\b|\[\s*/?if\b"#),
            ("else", #"(?i)(^|\s)else\b|\[\s*else\b"#),
            ("var", #"(?i)\bvar\s*(?:\(|:)"#),
            ("local", #"(?i)\blocal\s*(?:\(|:)"#),
            ("include", #"(?i)\binclude\s*(?:\(|:)"#),
            ("define", #"(?i)\bdefine\s+"#),
            ("protect", #"(?i)\bprotect\s+"#),
            ("iterate", #"(?i)\biterate\s*(?:\(|:)"#),
            ("loop", #"(?i)\bloop\s*(?:\(|:)"#),
            ("while", #"(?i)\bwhile\s*(?:\(|:)"#),
            ("match", #"(?i)\bmatch\s*(?:\(|:)"#),
            ("capture", #"(?i)\bcapture\s*(\(|=>)"#),
            ("assignment", #"(?i)(\$|#)?[A-Za-z_][A-Za-z0-9_]*\s*="#),
            ("dollar_variable", #"\$[A-Za-z_][A-Za-z0-9_]*"#),
            ("local_variable", #"#[A-Za-z_][A-Za-z0-9_]*"#),
            ("typed_declaration", #"(?i)::\s*[A-Za-z_][A-Za-z0-9_]*"#),
            ("closing_legacy_tag", #"(?i)^/\s*[A-Za-z_][A-Za-z0-9_]*"#)
        ]

        for (name, pattern) in constructPatterns where regex(pattern, matches: normalized) {
            result.constructs.add(name, file: file, line: line, excerpt: excerpt)
        }

        let inlineActions = ["-search", "-findall", "-random", "-add", "-update", "-delete", "-show", "-sql", "-prepare", "-nothing"]
        for action in inlineActions where lower.contains(action) {
            result.inlineParams.add(action, file: file, line: line, excerpt: excerpt)
        }

        for param in matches(#"(?i)-[A-Za-z][A-Za-z0-9_]*"#, in: normalized) {
            result.inlineParams.add(param.lowercased(), file: file, line: line, excerpt: excerpt)
        }

        for member in matches(#"(?i)(?:[A-Za-z_][A-Za-z0-9_]*|\)|\])\s*->\s*([A-Za-z_][A-Za-z0-9_]*)"#, in: normalized, group: 1) {
            result.memberCalls.add(member.lowercased(), file: file, line: line, excerpt: excerpt)
        }

        for call in matches(#"(?i)\b([A-Za-z_][A-Za-z0-9_]*)\s*\("#, in: normalized, group: 1) {
            let key = call.lowercased()
            result.functionCalls.add(key, file: file, line: line, excerpt: excerpt)
            if !knownCalls.contains(key) && !key.hasPrefix("_") {
                result.customCandidates.add(key, file: file, line: line, excerpt: excerpt)
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        let path = url.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func lineNumber(in text: String, at index: String.Index) -> Int {
        text[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private func regex(_ pattern: String, matches text: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)).map {
            !$0.matches(in: text, range: NSRange(text.startIndex..., in: text)).isEmpty
        } ?? false
    }

    private func matches(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

struct MarkdownReport {
    let result: ScanResult
    let root: String

    func render() -> String {
        var lines: [String] = []
        lines.append("# Lasso Subset Crawl")
        lines.append("")
        lines.append("- Root: `\(root)`")
        lines.append("- Files scanned: \(result.files)")
        lines.append("- Bytes scanned: \(result.bytes)")
        lines.append("")
        appendCounts(title: "File Extensions", counts: result.extensions.sorted { $0.key < $1.key }, lines: &lines)
        appendCounts(title: "Delimiters", counts: result.delimiterCounts.sorted { $0.key < $1.key }, lines: &lines)
        appendCounter(title: "Language Constructs", counter: result.constructs, lines: &lines)
        appendCounter(title: "Inline And Database Parameters", counter: result.inlineParams, lines: &lines)
        appendCounter(title: "Member Calls", counter: result.memberCalls, limit: 40, lines: &lines)
        appendCounter(title: "Function Calls", counter: result.functionCalls, limit: 60, lines: &lines)
        appendCounter(title: "Custom-Looking Function Calls", counter: result.customCandidates, limit: 80, lines: &lines)
        lines.append("")
        lines.append("## PerfectCRUD Implications")
        lines.append("")
        lines.append("- Lasso `inline` needs a dynamic query/result API: table names, selected fields, criteria fields, sort fields, and action names are strings at runtime.")
        lines.append("- PerfectCRUD already exposes connector-neutral SQL generation/execution delegates and raw SQL execution, but its ergonomic query API is Codable/key-path oriented.")
        lines.append("- Useful extensions would be dynamic table references, dynamic column projection, dynamic predicates, row dictionaries, and cursor metadata such as found count and affected rows.")
        lines.append("- Keep typed CRUD intact; add a sibling dynamic layer that reuses quoting, binding, logging, transactions, and connector delegates.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func appendCounts(title: String, counts: [(String, Int)], lines: inout [String]) {
        lines.append("## \(title)")
        lines.append("")
        for (key, count) in counts {
            lines.append("- `\(key)`: \(count)")
        }
        lines.append("")
    }

    private func appendCounter(title: String, counter: Counter, limit: Int = 30, lines: inout [String]) {
        lines.append("## \(title)")
        lines.append("")
        for (key, count) in counter.sortedCounts().prefix(limit) {
            lines.append("- `\(key)`: \(count)")
            for finding in (counter.examples[key] ?? []).sorted().prefix(3) {
                lines.append("  - \(finding.file):\(finding.line) — \(finding.excerpt)")
            }
        }
        lines.append("")
    }
}

extension Substring {
    func caseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        lowercased().hasPrefix(prefix.lowercased())
    }
}

extension String {
    func singleLineExcerpt(max: Int = 140) -> String {
        let compact = replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= max { return compact }
        return String(compact.prefix(max)) + "..."
    }
}

@main
struct LassoSubsetCrawler {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        var rootPath = FileManager.default.currentDirectoryPath
        var outputPath: String?
        var excludes: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--output", index + 1 < args.count {
                outputPath = args[index + 1]
                index += 2
            } else if arg == "--exclude", index + 1 < args.count {
                excludes.append(args[index + 1])
                index += 2
            } else {
                rootPath = arg
                index += 1
            }
        }
        let root = URL(fileURLWithPath: rootPath)
        let scanner = Scanner(root: root, rootPath: root.standardizedFileURL.path, excludes: excludes)
        let result = try scanner.run()
        let report = MarkdownReport(result: result, root: root.standardizedFileURL.path).render()
        if let outputPath {
            try report.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }
}
