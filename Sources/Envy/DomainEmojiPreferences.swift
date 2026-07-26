import Foundation

/// Per-domain emoji for link pills, stored as one JSON dictionary
/// (domain -> emoji) under a single AppStorage-friendly key — the same shape
/// TagColorPreferences uses.
///
/// Like a tag's color, this is a *preference*, not note content: the note holds
/// the plain URL, and the emoji is presentation keyed by the site's domain, so
/// every link to nytimes.com shows the same mark and nothing is written into
/// the file. Open the vault elsewhere and the emoji is simply absent.
enum DomainEmojiPreferences {
    static let storageKey = "domainEmojis"

    /// The quick picks in the right-click menu — a spread of source types a
    /// commonplace book tends to collect. "Other…" covers anything else.
    static let presets = ["📰", "📄", "📚", "📺", "🎥", "🎧", "🐙", "💻", "🛒", "💬", "⭐️", "🌐"]

    static func loadAll(from raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func encode(_ map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    static func emoji(for domain: String, raw: String) -> String? {
        loadAll(from: raw)[domain.lowercased()]
    }

    /// Sets (or, with nil, clears) a domain's emoji and returns the new raw
    /// string to store back.
    static func setting(_ emoji: String?, for domain: String, in raw: String) -> String {
        var map = loadAll(from: raw)
        let key = domain.lowercased()
        if let emoji, !emoji.isEmpty { map[key] = emoji } else { map[key] = nil }
        return encode(map)
    }

    /// The domain key for a URL — its host with any leading `www.` dropped,
    /// lowercased — matching how the styler derives the displayed domain.
    static func domainKey(for url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}
