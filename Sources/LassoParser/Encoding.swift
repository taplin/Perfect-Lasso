import Foundation

/// Shared string-encoding transforms backing both dialects Lasso exposes
/// them through: Lasso 8.5 tag-style (`[Encode_HTML: ...]`, `-EncodeHTML`
/// keywords on `[Output]`) and Lasso 9 method-style (`$string->encodeHtml`).
/// Grounded in `References/Lasso/Lasso 8.5 Language Guide.pdf` Chapter 17
/// "Encoding" (`Encoding Formats` section) and confirmed against the online
/// Lasso 9 reference (lassoguide.com/operations/strings.html via search —
/// the encoding keyword set is identical: `-encodeNone`, `-encodeHtml`,
/// `-encodeBreak`, `-encodeSmart`, `-encodeUrl`, `-encodeStrictUrl`,
/// `-encodeXml`, plus SQL/Base64 documented only on the Lasso 8.5 side).
/// See `Documentation/output-tags-plan.md`.
enum LassoEncoding {
    /// HTML Encoding — the default. Reuses the existing `String.htmlEncoded`
    /// extension (already used elsewhere, e.g. `->encodeHtml`) rather than
    /// introducing a second implementation.
    static func html(_ value: String) -> String {
        value.htmlEncoded
    }

    /// Smart HTML Encoding — encodes only extended-ASCII/foreign
    /// characters; HTML's own reserved characters (`< > " &`) are left
    /// alone so markup stays intact.
    static func smart(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if scalar.value > 127 {
                result += "&#\(scalar.value);"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Break Encoding — HTML-encodes the text, then converts line breaks
    /// to `<br>` tags.
    static func breakEncoded(_ value: String) -> String {
        html(value)
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    /// XML Encoding — the same reserved-character set as HTML, but `'`
    /// becomes the named `&apos;` entity (XML's convention) rather than
    /// HTML's numeric `&#39;`, so this isn't simply `html(_:)` reused.
    static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Simple URL Encoding — percent-encodes characters illegal in a URL
    /// without disturbing the rest of the URL's structure. Reuses the same
    /// `.urlQueryAllowed` charset the existing `->encodeUrl` string member
    /// already uses, so both call sites stay consistent.
    static func url(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// Strict URL Encoding — also encodes the reserved name/value-pair
    /// characters (`; / ? : @ = &`), for encoding just a parameter's name
    /// or value rather than a whole URL. RFC 3986 unreserved charset,
    /// matching the same convention already used in Perfect-Authentication
    /// for exactly this purpose.
    static func strictURL(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// SQL Encoding — escapes backslashes and quote marks so a string is
    /// safe to splice into a SQL string literal. Order matters: backslash
    /// first, so escaping the quotes below doesn't get re-escaped.
    static func sql(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Base 64 Encoding.
    static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    /// Every documented encoding keyword (`-EncodeNone`, `-EncodeHTML`,
    /// etc.), matched case-insensitively against an argument's label, in
    /// the order the Lasso 8.5 Language Guide lists them. `nil` for
    /// `-EncodeNone` since "no encoding" isn't a transform to apply.
    static func keyword(in arguments: [EvaluatedArgument]) -> String? {
        let names = ["none", "html", "smart", "break", "xml", "url", "stricturl", "sql", "base64"]
        for name in names where arguments.hasTruthyFlag("encode\(name)") {
            return name
        }
        return nil
    }

    /// Applies the named encoding (as returned by `keyword(in:)`, or the
    /// same names for the standalone `Encode_*` tags/methods). `nil`/
    /// `"none"` returns the value unchanged.
    static func apply(_ name: String?, to value: String) -> String {
        switch name?.lowercased() {
        case "html": html(value)
        case "smart": smart(value)
        case "break": breakEncoded(value)
        case "xml": xml(value)
        case "url": url(value)
        case "stricturl": strictURL(value)
        case "sql": sql(value)
        case "base64": base64(value)
        default: value
        }
    }
}
