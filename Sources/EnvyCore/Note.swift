import Foundation

// Title/tags/wikiLinks/lowercased-content used to be recomputed from scratch
// (regex scans, or a fresh .lowercased() of the full content) on every single
// access — fine for one note, but NoteStore.filtered(query:) touches these
// for every note on every search, and with a few thousand notes that adds up
// to thousands of regex passes and full-content lowercasings per keystroke.
//
// The fix isn't to compute these eagerly when a Note is constructed, though —
// that was tried first, and made reload() itself balloon to 2+ seconds at
// 10,000 notes, since a plain folder scan now had to run both regexes (tags,
// wikiLinks) and a full lowercase over every single note's content whether
// or not anything actually needed them yet (most reloads never touch tag: or
// backlinks at all). Instead this is computed lazily, once, on whichever
// property is first actually read, and cached from then on — reload() stays
// a cheap file-read pass, and repeated search/tag/backlink lookups still hit
// a cache instead of recomputing every time.
//
// Backed by a class (not stored directly on the struct) so the lazy
// memoization can happen without Note itself needing to be `var`/mutating —
// a `let note = ...` or a `for note in notes` loop can still trigger and
// benefit from the cache. Copying a Note copies the reference, not the
// cache's contents, which is exactly right: two copies with identical
// content/url can safely share one cache, and content/url's own didSet
// swaps in a fresh cache the moment either actually changes.
private final class NoteDerivedCache: @unchecked Sendable {
    let url: URL
    let content: String

    init(url: URL, content: String) {
        self.url = url
        self.content = content
    }

    // Only ever touched from the main actor in practice (NoteStore, the sole
    // consumer, is @MainActor) — scanDirectories() constructs Notes on a
    // background thread but never reads these lazy properties itself, so
    // there's no real concurrent access despite the class not being
    // inherently thread-safe on its own.
    lazy var title: String = {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }()

    lazy var lowercasedTitle: String = title.lowercased()
    lazy var lowercasedContent: String = content.lowercased()

    lazy var tags: Set<String> = {
        let matches = Note.tagRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return Set(matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            return content[range].lowercased()
        })
    }()

    lazy var wikiLinks: Set<String> = {
        let matches = Note.wikiLinkRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return Set(matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: content) else { return nil }
            let title = content[range].trimmingCharacters(in: .whitespaces).lowercased()
            return title.isEmpty ? nil : title
        })
    }()

    // Only needs to know whether at least one exists, for the "todo:"
    // search operator — firstMatch stops at the first hit rather than
    // scanning the rest of the note once one's found, so this is cheaper
    // than tags/wikiLinks above even though it runs a regex too. Deliberately
    // a separate, narrower pattern from MarkdownStyler's own task-list regex
    // (which lives in the Envy module, not reachable from here, and also
    // handles rendering concerns like the marker/content capture groups that
    // this doesn't need) — just "is there a literal, unchecked '[ ]' task
    // marker at the start of some line," matching the same dash-optional
    // shape MarkdownStyler recognizes.
    lazy var hasUncheckedTask: Bool = {
        Note.uncheckedTaskRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
    }()
}

public struct Note: Identifiable, Sendable {
    public let id: String
    public var url: URL {
        didSet { guard url != oldValue else { return }; cache = NoteDerivedCache(url: url, content: content) }
    }
    public var content: String {
        didSet { guard content != oldValue else { return }; cache = NoteDerivedCache(url: url, content: content) }
    }
    public var modifiedDate: Date

    private var cache: NoteDerivedCache

    public init(id: String, url: URL, content: String, modifiedDate: Date) {
        self.id = id
        self.url = url
        self.content = content
        self.modifiedDate = modifiedDate
        self.cache = NoteDerivedCache(url: url, content: content)
    }

    public var title: String { cache.title }
    public var lowercasedTitle: String { cache.lowercasedTitle }
    public var lowercasedContent: String { cache.lowercasedContent }

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
    public var tags: Set<String> { cache.tags }

    fileprivate static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\w#])#([A-Za-z0-9_-]+)"#)

    /// Titles of every note this one links to via `[[Title]]`, lowercased
    /// for case-insensitive lookups — same convention as
    /// NoteStore.exactTitleMatch(for:), which is what actually resolves a
    /// wiki-link on click, so a link matches its target here exactly when
    /// it would there. Trimmed since a title typed inside "[[ ]]" can pick
    /// up incidental leading/trailing whitespace.
    public var wikiLinks: Set<String> { cache.wikiLinks }

    fileprivate static let wikiLinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)

    /// Whether this note has at least one still-unchecked task-list item —
    /// backs the "todo:" search operator.
    public var hasUncheckedTask: Bool { cache.hasUncheckedTask }

    fileprivate static let uncheckedTaskRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+][ \t]+)?\[ \][ \t]+"#, options: [.anchorsMatchLines]
    )

    /// The name of the folder this note directly lives in — backs the
    /// "folder:" search operator. A plain path-component lookup, not
    /// cached like the regex-derived properties above: no scan involved,
    /// so there's nothing expensive here to save by caching it.
    public var folderName: String { url.deletingLastPathComponent().lastPathComponent }
}

extension Note: Equatable {
    // Custom rather than synthesized: the cache is a pure function of
    // url/content, so comparing it too would be redundant work on top of
    // the fields that already fully determine equality.
    public static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.content == rhs.content && lhs.modifiedDate == rhs.modifiedDate
    }
}
