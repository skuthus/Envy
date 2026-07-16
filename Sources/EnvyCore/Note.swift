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
    // editor. Only the first ACTIVE "@..." token found is honored — a due
    // date is a single per-note property, not a list — where "active"
    // means neither of two ways a due token gets retired:
    // - crossed out: a token anywhere inside a "~~...~~" span, the same
    //   way marking a task done removes it from view. Broader than "did a
    //   click specifically wrap just this token" (that exact shape is
    //   MarkdownStyler.dueTokenRanges' own, narrower concern, for toggling
    //   one token's wrap on click) — crossing out a whole sentence that
    //   happens to contain a due token should retire it too.
    // - on a checked task-list line: "- [x] Ship the report @04-16-26"
    //   retires the due token without any "~~" ever being written to
    //   disk — checking a box is a rendering-time overlay in
    //   MarkdownStyler, not a text edit, so there's no strikethrough
    //   markup for this property to see. Recognized directly here instead
    //   via checkedTaskLineRegex, matching the same "[x]"/"[X]" shape
    //   MarkdownStyler's own taskListRegex checks, restricted to the
    //   checked state and the token's whole line (a due token can appear
    //   anywhere after the checkbox marker, not just right after it).
    // Each token is either an absolute date ("@04-16-26" / "@2026-04-16"),
    // "@today", or a day name ("@monday"), which always means the *next*
    // occurrence of that day — see NoteStore.resolveDueToken for why
    // that's fine to resolve fresh every time despite the general rule
    // against live relative resolution (explained there): everything else
    // (arbitrary phrases like "next week") still belongs in the editor as
    // a type-time transform that freezes into a literal absolute date
    // before it's ever saved, not here.
    var due: Date? {
        memoized(&_due) {
            let fullRange = NSRange(content.startIndex..., in: content)
            // Found (and only found) once per note, then reused for every
            // caller for the rest of that Note's lifetime — but the two
            // exclusion scans below are worth skipping entirely for the
            // common case (most notes have no due token at all), rather
            // than always paying for them just to find nothing to exclude.
            let dueMatches = Note.dueRegex.matches(in: content, range: fullRange)
            guard !dueMatches.isEmpty else { return nil }
            let strikethroughRanges = Note.strikethroughRegex.matches(in: content, range: fullRange).map(\.range)
            let checkedTaskLineRanges = Note.checkedTaskLineRegex.matches(in: content, range: fullRange).map(\.range)
            func isRetired(_ range: NSRange) -> Bool {
                strikethroughRanges.contains { NSIntersectionRange($0, range).length > 0 }
                    || checkedTaskLineRanges.contains { NSIntersectionRange($0, range).length > 0 }
            }
            guard let match = dueMatches.first(where: { !isRetired($0.range) }),
                  let range = Range(match.range(at: 1), in: content) else { return nil }
            let token = String(content[range])
            return NoteStore.resolveDueToken(token)
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

    /// The date from this note's first "@..." token, if any and if it
    /// parses — see NoteDerivedCache.due above for what "if it parses"
    /// covers (an absolute date, or a day name resolved to its next
    /// occurrence). Backs the "due:" search operator, the due-date sort
    /// field, and the due-date chip/color in the editor.
    public var due: Date? { cache.due }

    /// The negative lookbehind excludes "@" preceded by a word character
    /// (mid-word, not the token) — same shape as Note.tagRegex's own
    /// exclusion. The capture group only matches a day name or a run of
    /// date-shaped characters (digits, "-", "/") rather than a greedy \S+
    /// — besides \S+ swallowing trailing punctuation with no space before
    /// it ("@04-16-26, call the client" captured "04-16-26," comma
    /// included, which then failed Int parsing on the year and silently
    /// produced no due date at all), restricting the alternatives at all is
    /// what keeps an ordinary "@mention" (a name, a handle, anything that
    /// isn't a day name or date-shaped) from being misread as a due token
    /// in the first place. The trailing negative lookahead excludes a
    /// word character right after the match too, so "@mondayish" doesn't
    /// partially match "@monday". An unparseable token (resolveDueToken
    /// returns nil) just means no due date, not a crash — same forgiving
    /// failure mode as a malformed tag or wiki-link.
    fileprivate static let dueRegex = try! NSRegularExpression(
        pattern: #"(?<![\w])@(today|monday|tuesday|wednesday|thursday|friday|saturday|sunday|[0-9/-]+)(?!\w)"#,
        options: [.caseInsensitive]
    )

    /// Matches MarkdownStyler's own strikethroughRegex in the Envy module
    /// exactly (duplicated rather than shared — that one's private to its
    /// own target, same reasoning as tagRegex/dueRegex above) — used only
    /// to tell whether a due token falls inside a crossed-out span.
    fileprivate static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)

    /// A whole checked task-list line, start to end — same "[x]"/"[X]"
    /// shape MarkdownStyler's own taskListRegex checks, restricted to the
    /// checked state and capturing the full line (not just the marker)
    /// since a due token can appear anywhere in the line's remaining text,
    /// not necessarily right after the checkbox. Used only to tell whether
    /// a due token sits on an already-completed task line — see `due`
    /// above for why that retires it the same as being crossed out.
    fileprivate static let checkedTaskLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+][ \t]+)?\[[xX]\][ \t]+.*$"#, options: [.anchorsMatchLines]
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
