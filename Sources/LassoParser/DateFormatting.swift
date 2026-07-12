import Foundation

/// Lasso's date model is fundamentally wall-clock-oriented (year/month/day
/// hour/minute/second, no attached time zone) — `Date_LocalToGMT`/
/// `Date_GMTToLocal` exist specifically because a raw value doesn't know
/// which zone it's in. `Foundation.Date` conflates "an absolute instant"
/// with "a time zone" in a way that doesn't match, so this interpreter
/// stores the six wall-clock components directly rather than an instant.
/// See `Documentation/date-format-plan.md`.
struct LassoDateComponents: Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int

    /// A fixed GMT calendar used purely as neutral arithmetic — every
    /// component here is wall-clock, not GMT-relative, until
    /// `Date_LocalToGMT`/`Date_GMTToLocal` explicitly shift it. Building a
    /// `Foundation.Date` against GMT is just how the components get a
    /// concrete instant to hand `DateFormatter`/`Calendar` without a
    /// second, unwanted zone shift sneaking in.
    private static var referenceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    var asDate: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Self.referenceCalendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    init(date: Date) {
        let components = Self.referenceCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
        hour = components.hour ?? 0
        minute = components.minute ?? 0
        second = components.second ?? 0
    }

    static func now() -> LassoDateComponents {
        LassoDateComponents(date: Date())
    }

    /// Lasso's own Sunday=1...Saturday=7 numbering — this happens to be
    /// exactly what `Calendar`'s `.weekday` component already returns for
    /// a Gregorian calendar, no translation needed.
    var weekday: Int {
        Self.referenceCalendar.component(.weekday, from: asDate)
    }

    var weekOfYear: Int {
        Self.referenceCalendar.component(.weekOfYear, from: asDate)
    }
}

/// Parses a value into `LassoDateComponents`, matching Lasso 8.5's `[Date]`
/// tag ("auto-recognizes... a valid date string") and Lasso 9's date
/// creator method. See `Documentation/date-format-plan.md`.
enum LassoDateParsing {
    /// Recognized formats, tried in order — covers every real corpus shape
    /// this pass targets (Chapter 29's own worked examples plus what's
    /// actually used). A `DateFormatter` per pattern, not one reused
    /// instance with a mutated `dateFormat`, so parsing never races with
    /// the formatting side's own reuse.
    private static let recognizedFormats = [
        "M/d/yyyy H:mm:ss",
        "M/d/yyyy H:mm",
        "M/d/yyyy",
        "yyyy-MM-dd H:mm:ss",
        "yyyy-MM-dd H:mm",
        "yyyy-MM-dd",
        "yyyyMMddHHmmss",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
    ]

    private static func makeFormatter(pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = pattern
        return formatter
    }

    /// `explicitFormat` is a Lasso `%`-symbol pattern (from `[Date:
    /// dateString, -Format='...']`) forcing how an otherwise-ambiguous
    /// string should be read — translated to the same ICU pattern
    /// `LassoDateFormatting` uses for output, then parsed with it first.
    static func parse(_ value: LassoValue, explicitFormat: String? = nil) -> LassoDateComponents? {
        switch value {
        case let .object(object) where object.typeName.caseInsensitiveCompare("date") == .orderedSame:
            return dateComponents(from: object)
        case .void, .null:
            return nil
        default:
            let text = value.outputString.trimmingCharacters(in: .whitespaces)
            guard text.isEmpty == false else { return nil }

            if let explicitFormat {
                let icuPattern = LassoDateFormatting.icuPattern(forLassoFormat: explicitFormat)
                if let date = makeFormatter(pattern: icuPattern).date(from: text) {
                    return LassoDateComponents(date: date)
                }
            }
            for pattern in recognizedFormats {
                if let date = makeFormatter(pattern: pattern).date(from: text) {
                    return LassoDateComponents(date: date)
                }
            }
            return nil
        }
    }

    static func makeObject(_ components: LassoDateComponents) -> LassoObjectInstance {
        LassoObjectInstance(typeName: "date", data: [
            "year": .integer(components.year),
            "month": .integer(components.month),
            "day": .integer(components.day),
            "hour": .integer(components.hour),
            "minute": .integer(components.minute),
            "second": .integer(components.second),
        ])
    }

    static func dateComponents(from object: LassoObjectInstance) -> LassoDateComponents? {
        guard case let .integer(year) = object.value(for: "year"),
              case let .integer(month) = object.value(for: "month"),
              case let .integer(day) = object.value(for: "day") else {
            return nil
        }
        func intField(_ name: String) -> Int {
            if case let .integer(value) = object.value(for: name) { return value }
            return 0
        }
        return LassoDateComponents(
            year: year, month: month, day: day,
            hour: intField("hour"), minute: intField("minute"), second: intField("second")
        )
    }
}

/// Formats `LassoDateComponents` using Lasso's documented `%`-symbol table
/// (Lasso 8.5 Language Guide Chapter 29, Table 2 — confirmed identical in
/// the online Lasso 9 reference, lassoguide.com/operations/date-duration.html,
/// just exposed as a `date->format` method there instead of a free tag).
/// Renders through `DateFormatter`'s ICU pattern language rather than
/// hand-computed strings or system `strftime` — see
/// `Documentation/date-format-plan.md` for why `strftime` specifically was
/// rejected (several Lasso symbols share `%`-spelling with different
/// `strftime` meanings; ICU's letter-repetition syntax has no such
/// collision since it isn't `%`-prefixed at all).
enum LassoDateFormatting {
    /// Every symbol with a direct one-line ICU equivalent. `%h` intentionally
    /// maps to ICU's 12-hour-hour letter — unrelated to (and not a
    /// collision with) `strftime`'s different `%h` (abbreviated month).
    private static let icuPatterns: [Character: (padded: String, unpadded: String)] = [
        "Y": ("yyyy", "yyyy"),
        "y": ("yy", "yy"),
        "m": ("MM", "M"),
        "B": ("MMMM", "MMMM"),
        "b": ("MMM", "MMM"),
        "d": ("dd", "d"),
        "A": ("EEEE", "EEEE"),
        "a": ("EEE", "EEE"),
        "H": ("HH", "H"),
        "h": ("hh", "h"),
        "M": ("mm", "m"),
        "S": ("ss", "s"),
        "p": ("a", "a"),
        "T": ("HH:mm:ss", "HH:mm:ss"),
        "r": ("hh:mm:ss a", "h:mm:ss a"),
        "D": ("MM/dd/yyyy", "M/d/yyyy"),
        "Q": ("yyyy-MM-dd", "yyyy-MM-dd"),
        "q": ("yyyyMMddHHmmss", "yyyyMMddHHmmss"),
        "z": ("Z", "Z"),
        "Z": ("zzz", "zzz"),
    ]

    /// Symbols Lasso defines that have no ICU pattern-letter equivalent at
    /// all and are computed directly from `LassoDateComponents`.
    private static let directSymbols: Set<Character> = ["w", "W", "G"]

    private static func formatter(pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = pattern
        return formatter
    }

    /// Translates one Lasso `%`-symbol format string into a single ICU
    /// pattern — used when an explicit `-Format` on `[Date: ..., -Format=...]`
    /// needs to drive *parsing* rather than output. Only meaningful for
    /// formats built entirely from the direct-ICU-equivalent symbols above;
    /// falls back to the symbol name itself (effectively a no-op pattern)
    /// for anything else, since parsing with `%w`/`%W`/`%G` doesn't make
    /// sense (they're output-only, real Lasso's own docs don't describe
    /// parsing with them either).
    static func icuPattern(forLassoFormat format: String) -> String {
        var result = ""
        var iterator = format.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            guard let symbol = iterator.next() else { break }
            if symbol == "%" {
                result.append("%")
                continue
            }
            if let mapped = icuPatterns[symbol] {
                result += mapped.padded
            }
        }
        return result
    }

    static func format(_ components: LassoDateComponents, using formatString: String) -> String {
        let date = components.asDate
        var result = ""
        let characters = Array(formatString)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "%" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { break }

            var padding: Character?
            if characters[index] == "_" || characters[index] == "-" {
                padding = characters[index]
                index += 1
                guard index < characters.count else { break }
            }
            let symbol = characters[index]
            index += 1

            if symbol == "%" {
                result.append("%")
                continue
            }

            if directSymbols.contains(symbol) {
                result += formatDirectSymbol(symbol, components: components, padding: padding)
                continue
            }

            guard let mapped = icuPatterns[symbol] else {
                // Unknown symbol — pass the two characters through
                // literally rather than silently dropping them, matching
                // this interpreter's "don't silently eat unrecognized
                // input" posture elsewhere.
                result.append("%")
                if let padding { result.append(padding) }
                result.append(symbol)
                continue
            }

            switch padding {
            case "-":
                result += formatter(pattern: mapped.unpadded).string(from: date)
            case "_":
                let raw = formatter(pattern: mapped.unpadded).string(from: date)
                result += raw.count < 2 ? String(repeating: " ", count: 2 - raw.count) + raw : raw
            default:
                result += formatter(pattern: mapped.padded).string(from: date)
            }
        }
        return result
    }

    private static func formatDirectSymbol(_ symbol: Character, components: LassoDateComponents, padding: Character?) -> String {
        switch symbol {
        case "w":
            return String(components.weekday)
        case "W":
            let value = components.weekOfYear
            return padding == "-" ? String(value) : (value < 10 ? "0\(value)" : String(value))
        case "G":
            // No corpus/doc example precise enough to confirm exact
            // rendering — lowest-confidence symbol in the table. Real
            // Lasso's own docs just call it "GMT time zone indicator";
            // this interpreter always renders wall-clock components with
            // no attached zone, so a fixed literal is the honest answer
            // rather than fabricating a real offset.
            return "GMT"
        default:
            return ""
        }
    }
}
