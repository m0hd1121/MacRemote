import Foundation

/// Removes credentials from text before it reaches any log. Applied to every log message.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // PEM private keys (multi-line).
            ("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----", "[REDACTED PRIVATE KEY]"),
            // Tailscale auth keys / API keys / OAuth secrets.
            ("tskey-[A-Za-z0-9_-]+", "tskey-[REDACTED]"),
            // Tailscale interactive login URLs (single-use but grant node auth).
            ("https://login\\.tailscale\\.com/a/[A-Za-z0-9]+", "https://login.tailscale.com/a/[REDACTED]"),
            // Authorization headers.
            ("(?i)(authorization\\s*[:=]\\s*)(bearer|basic|token)\\s+[A-Za-z0-9._~+/=-]+", "$1$2 [REDACTED]"),
            ("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer [REDACTED]"),
            // key=value / key: value secrets.
            ("(?i)\\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)(\"?\\s*[:=]\\s*\"?)[^\\s\"&,;]+", "$1$2[REDACTED]"),
            // Credentials embedded in URLs: scheme://user:pass@host
            ("([a-zA-Z][a-zA-Z0-9+.-]*://[^\\s:/@]+):[^\\s@/]+@", "$1:[REDACTED]@"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }
}
