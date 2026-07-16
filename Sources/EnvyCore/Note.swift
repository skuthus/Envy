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
// Backed by a class (not stored directly on the struct) so the
// memoization can happen without Note itself needing to be `var`/mutating —
// a `let note = ...` or a `for note in notes` loop can still trigger and
// benefit from the cache. Copying a Note copies the reference, not the
// cache's contents, which is exactly right: two copies with identical
// content/url can safely share one cache, and content/url's own didSet
// swaps in a fresh cache the moment either actually changes.
//
// Lock-guarded compute-once properties rather than `lazy var`: search now
// runs on a background task over a snapshot of the same Note values the
// main thread keeps rendering (NoteRow reads title/preview while a search
// reads lowercasedContent), and Swift's `lazy` is not thread-safe — two
// threads racing the first access can compute twice or, worse, tear the
// write. The lock is uncontended in practice (nanoseconds per access);
// compute still happens at most once per property.
private final class NoteDerivedCache: @unchecked Sendable {
    let url: URL
    let content: String

    private let lock = NSLock()
    private var _title: String?
    private var _lowercasedTitle: String?
    private var _lowercasedContent: String?
    private var _tags: Set<String>?
    private var _wikiLinks: Set<String>?
    private var _hasUncheckedTask: Bool?
    private var _preview: String?
    private var _due: Date??

    init(url: URL, content: String) {
        self.url = url
        self.content = content
    }

    private func memoized<T>(_ storage: inout T?, compute: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if let value = storage { return value }
        let value = compute()
        storage = value
        return value
    }

    var title: String {
        memoized(&_title) {
            let name = url.deletingPathExtension().lastPathComponent
            return name.isEmpty ? "Untitled" : name
        }
    }

    var lowercasedTitle: String {
        // `title` resolved before entering memoized — its accessor takes
        // the same (non-recursive) lock, so reading it inside the compute
        // closure would deadlock.
        let resolvedTitle = title
        return memoized(&_lowercasedTitle) { resolvedTitle.lowercased() }
    }

    var lowercasedContent: String {
        memoized(&_lowercasedContent) { content.lowercased() }
    }

    var tags: Set<String> {
        memoized(&_tags) {
            let matches = Note.tagRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            return Set(matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: content) else { return nil }
                return content[range].lowercased()
            })
        }
    }

    var wikiLinks: Set<String> {
        memoized(&_wikiLinks) {
            let matches = Note.wikiLinkRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            return Set(matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: content) else { return nil }
                let title = content[range].trimmingCharacters(in: .whitespaces).lowercased()
                return title.isEmpty ? nil : title
            })
        }
    }

    // Backs the "due:" search operator and the due-date chip/color in the
    // editor. Only the first "due@..." token found is honored — a due date
    // is a single per-note property, not a list. Only ever an absolute date
    // ("due@04-16-26" / "due@2026-04-16"): resolving something like
    // "due@today" live, on every access, would mean a note written months
    // ago and never touched again still silently claims to be due "today"
    // forever, which defeats the point of a due date. Relative shorthand
    // belongs in the editor as a type-time transform that freezes into a
    // literal absolute date before it's ever saved, not here.
    var due: Date? {
        memoized(&_due) {
            guard let match = Note.dueRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
                  let range = Range(match.range(at: 1), in: content) else { return nil }
            let token = String(content[range])
            guard let components = NoteStore.parseFlexibleDate(token) else { return nil }
            return Calendar.current.date(from: components)
        }
    }

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
    var hasUncheckedTask: Bool {
        memoized(&_hasUncheckedTask) {
            Note.uncheckedTaskRegex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
        }
    }

    // The list row shows the preview as a single truncated line, so only
    // roughly the first line's worth of characters can ever render —
    // building it used to split the note's *entire* content on every access
    // anyway, and (being the one derived property left as a plain computed
    // property on Note) it did so on every list-row render while scrolling,
    // twice per row. Capped and cached here with the rest. The manual
    // line walk (rather than content.split) is what makes the cap real:
    // split would still scan and allocate every line of the whole note
    // before the first one could be looked at.
    var preview: String {
        memoized(&_preview) {
            let cap = 200
            var result = ""
            var index = content.startIndex
            while index < content.endIndex, result.count < cap {
                let lineEnd = content[index...].firstIndex(of: "\n") ?? content.endIndex
                let line = content[index..<lineEnd]
                if !line.isEmpty {
                    if !result.isEmpty { result += " " }
                    result += line
                }
                index = lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex
            }
            return result
        }
    }
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

    /// A single-line snippet for the note list row — cached and capped, see
    /// NoteDerivedCache.preview.
    public var preview: String { cache.preview }

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

    /// The date from this note's first "due@..." token, if any and if it
    /// parses — see NoteDerivedCache.due above for why this is absolute-date
    /// only, no relative shorthand. Backs the "due:" search operator, the
    /// due-date sort field, and the due-date chip/color in the editor.
    public var due: Date? { cache.due }

    /// The negative lookbehind excludes "due@" preceded by a word character
    /// (mid-word, not the token) — same shape as Note.tagRegex's own
    /// exclusion. The capture group is restricted to date-shaped characters
    /// (digits, "-", "/") rather than a greedy \S+ — \S+ also swallows
    /// trailing punctuation with no space before it ("due@04-16-26, call
    /// the client" captured "04-16-26," comma included, which then failed
    /// Int parsing on the year and silently produced no due date at all).
    /// An unparseable token (parseFlexibleDate returns nil) just means no
    /// due date, not a crash — same forgiving failure mode as a malformed
    /// tag or wiki-link.
    fileprivate static let dueRegex = try! NSRegularExpression(pattern: #"(?<![\w])due@([0-9/-]+)"#, options: [.caseInsensitive])

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
