import Foundation

public struct Note: Identifiable, Equatable, Sendable {
    public let id: String
    public var url: URL
    public var content: String
    public var modifiedDate: Date

    public init(id: String, url: URL, content: String, modifiedDate: Date) {
        self.id = id
        self.url = url
        self.content = content
        self.modifiedDate = modifiedDate
    }

    public var title: String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }

    public var preview: String {
        content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// `#word`-style hashtags found anywhere in the note's content, lowercased
    /// for case-insensitive matching. The negative lookbehind excludes "#"
    /// preceded by a word character (mid-word, not a tag) or another "#"
    /// (would otherwise match inside "## Heading"); markdown headings
    /// themselves ("# Heading") are already excluded since they require a
    /// space right after the "#", which this pattern doesn't allow.
    public var tags: Set<String> {
        let matches = Note.tagRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return Set(matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            return content[range].lowercased()
        })
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\w#])#([A-Za-z0-9_-]+)"#)
}
