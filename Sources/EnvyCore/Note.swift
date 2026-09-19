import Foundation

/// Whether a note carries an AI-provenance signature — the "⎈ created/edited
/// by … · <date>" line an external AI connector stamps as the last line (see
/// the Envy Connector project). Envy itself never writes these; it only
/// reads them, to surface which notes an AI touched. A self-attested claim,
/// not something Envy can verify — so UI wording says "marked as," never
/// asserts. Backs the "ai:" search operator and the note-list badge.
public enum AIProvenance: String, Sendable {
    case none      // no signature — a purely human note
    case created   // authored from scratch by an AI
    case edited    // a human note an AI later modified
}

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
    private var _imageEmbedTargets: Set<String>?
    private var _hasUncheckedTask: Bool?
    private var _embedKinds: (image: Bool, note: Bool)?
    private var _preview: String?
    private var _activeDueDates: [Date]?
    private var _aiProvenance: AIProvenance?

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
            let matches = NoteMarkup.tagRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            return Set(matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: content) else { return nil }
                return content[range].lowercased()
            })
        }
    }

    /// Note-to-note link targets (`[[Title]]` and note embeds `![[Title]]`),
    /// never image attachments. `NoteMarkup.wikiLinkRegex` alone would also
    /// match the `[[…]]` inside `![[photo.png]]`; those are attachment refs,
    /// not graph edges — see `imageEmbedTargets`. Note embeds still count
    /// here so orphan:/link:/interlink:/rename keep treating a transclusion
    /// as a real connection to that note.
    var wikiLinks: Set<String> {
        memoized(&_wikiLinks) {
            var links = Set<String>()
            let nsContent = content as NSString
            let full = NSRange(location: 0, length: nsContent.length)

            for match in NoteMarkup.wikiLinkRegex.matches(in: content, range: full) {
                // Skip `![[…]]` — image vs note embed is decided below.
                if match.range.location > 0,
                   nsContent.character(at: match.range.location - 1) == 33 /* ! */ {
                    continue
                }
                guard let range = Range(match.range(at: 1), in: content) else { continue }
                // The *target*, not the raw body — otherwise [[Note|alias]]
                // registers a link to a note called "Note|alias", which can't
                // exist, and the real note loses the backlink.
                let title = WikiLink.parse(String(content[range])).target.lowercased()
                if !title.isEmpty { links.insert(title) }
            }

            guard content.contains("![[") else { return links }
            for match in NoteMarkup.embedRegex.matches(in: content, range: full) {
                guard let parsed = Note.parseEmbedInner(match, in: content),
                      !parsed.isImage else { continue }
                let title = WikiLink.parse(parsed.name).target.lowercased()
                if !title.isEmpty { links.insert(title) }
            }
            return links
        }
    }

    /// Lowercased attachment filenames referenced by `![[photo.png]]`
    /// (size/caption suffixes stripped). Backs OCR search and attachment
    /// rename rewrites — kept separate from `wikiLinks` so image refs don't
    /// pollute the note-link graph.
    var imageEmbedTargets: Set<String> {
        memoized(&_imageEmbedTargets) {
            guard content.contains("![[") else { return [] }
            var names = Set<String>()
            let full = NSRange(content.startIndex..., in: content)
            for match in NoteMarkup.embedRegex.matches(in: content, range: full) {
                guard let parsed = Note.parseEmbedInner(match, in: content),
                      parsed.isImage else { continue }
                names.insert(parsed.name.lowercased())
            }
            return names
        }
    }

    /// Whether the note contains an image embed and/or a note-transclusion
    /// embed — both `![[...]]`, told apart by whether the target's extension is
    /// an image. Computed in one pass and memoized, behind a cheap substring
    /// early-out so the majority of notes (no `![[` at all) pay nothing. Backs
    /// the `img:` and `embed:` search operators.
    var embedKinds: (image: Bool, note: Bool) {
        memoized(&_embedKinds) {
            guard content.contains("![[") else { return (false, false) }
            var hasImage = false, hasNote = false
            let matches = NoteMarkup.embedRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                guard let parsed = Note.parseEmbedInner(match, in: content) else { continue }
                if parsed.isImage { hasImage = true } else { hasNote = true }
                if hasImage && hasNote { break }
            }
            return (hasImage, hasNote)
        }
    }

    var aiProvenance: AIProvenance {
        memoized(&_aiProvenance) {
            let full = NSRange(content.startIndex..., in: content)
            guard let match = NoteMarkup.aiSignatureRegex.firstMatch(in: content, range: full),
                  let range = Range(match.range(at: 1), in: content) else { return .none }
            return content[range] == "created" ? .created : .edited
        }
    }

    // Every ACTIVE "@..." token's resolved date, sorted earliest first —
    // "active" means neither of two ways a due token gets retired:
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
    // "@today"/"@tomorrow"/"@yesterday", or a day name ("@monday"), which
    // always means the *next* occurrence of that day — see
    // NoteStore.resolveDueToken for why
    // that's fine to resolve fresh every time despite the general rule
    // against live relative resolution (explained there): everything else
    // (arbitrary phrases like "next week") still belongs in the editor as
    // a type-time transform that freezes into a literal absolute date
    // before it's ever saved, not here.
    //
    // Sorted (not just "the first token found in the text") because
    // `due` below is the *earliest* of these — the one that actually
    // determines urgency and drives due-column sorting — not whichever
    // token happens to appear first in reading order. A note mentioning a
    // later date before an earlier one used to report the later, less
    // urgent date as "the" due date purely because of where it sat in the
    // text; a real bug, not a deliberate design choice.
    var activeDueDates: [Date] {
        memoized(&_activeDueDates) {
            let fullRange = NSRange(content.startIndex..., in: content)
            // Found (and only found) once per note, then reused for every
            // caller for the rest of that Note's lifetime — but the two
            // exclusion scans below are worth skipping entirely for the
            // common case (most notes have no due token at all), rather
            // than always paying for them just to find nothing to exclude.
            let dueMatches = NoteMarkup.dueRegex.matches(in: content, range: fullRange)
            guard !dueMatches.isEmpty else { return [] }
            let strikethroughRanges = NoteMarkup.strikethroughRegex.matches(in: content, range: fullRange).map(\.range)
            let checkedTaskLineRanges = Note.checkedTaskLineRegex.matches(in: content, range: fullRange).map(\.range)
            func isRetired(_ range: NSRange) -> Bool {
                strikethroughRanges.contains { NSIntersectionRange($0, range).length > 0 }
                    || checkedTaskLineRanges.contains { NSIntersectionRange($0, range).length > 0 }
            }
            return dueMatches.compactMap { match -> Date? in
                guard !isRetired(match.range), let range = Range(match.range(at: 1), in: content) else { return nil }
                let token = String(content[range])
                return NoteStore.resolveDueToken(token)
            }.sorted()
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

    /// Titles of every note this one links to via `[[Title]]` or a note
    /// embed `![[Title]]`, lowercased for case-insensitive lookups — same
    /// convention as NoteStore.exactTitleMatch(for:), which is what actually
    /// resolves a wiki-link on click, so a link matches its target here
    /// exactly when it would there. Image embeds (`![[photo.png]]`) are
    /// *not* included; see `imageEmbedTargets`. Trimmed since a title typed
    /// inside "[[ ]]" can pick up incidental leading/trailing whitespace.
    public var wikiLinks: Set<String> { cache.wikiLinks }

    /// Lowercased image-attachment filenames this note embeds via
    /// `![[photo.png]]` (optional `|size` / caption stripped). Used by OCR
    /// search and attachment rename rewrites.
    public var imageEmbedTargets: Set<String> { cache.imageEmbedTargets }

    /// Which AI-provenance signature, if any, this note carries — see the
    /// AIProvenance enum. Backs the "ai:" search operator and the note-list
    /// badge.
    public var aiProvenance: AIProvenance { cache.aiProvenance }

    /// Whether this note has at least one still-unchecked task-list item —
    /// backs the "todo:" search operator.
    public var hasUncheckedTask: Bool { cache.hasUncheckedTask }

    /// Whether the note embeds at least one image — backs the `img:` operator.
    public var hasImageEmbed: Bool { cache.embedKinds.image }
    /// Whether the note transcludes at least one other note — backs `embed:`.
    public var hasNoteEmbed: Bool { cache.embedKinds.note }

    /// Extensions that make a `![[…]]` target an image rather than a note
    /// embed — shared with MarkdownStyler via this set.
    public static let imageAttachmentExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]

    /// Target name + whether it's an image attachment, from one
    /// `NoteMarkup.embedRegex` match. Strips `|size` / caption so
    /// `photo.png|400` still classifies as an image.
    fileprivate static func parseEmbedInner(_ match: NSTextCheckingResult, in content: String) -> (name: String, isImage: Bool)? {
        guard let range = Range(match.range(at: 1), in: content) else { return nil }
        let inner = content[range]
        let name = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(inner)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isImage = imageAttachmentExtensions.contains((trimmed as NSString).pathExtension.lowercased())
        return (trimmed, isImage)
    }

    fileprivate static let uncheckedTaskRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+][ \t]+)?\[ \][ \t]+"#, options: [.anchorsMatchLines]
    )

    /// The *earliest* active due date among this note's "@..." tokens, if
    /// any — see NoteDerivedCache.activeDueDates above for what "active"
    /// and "if it parses" cover. Backs the "due:" search operator, the
    /// due-date sort field, and the due-date chip/color in the editor.
    public var due: Date? { cache.activeDueDates.first }

    /// How many distinct active due dates this note has — 1 in the common
    /// case, more if a note tracks several sub-tasks each with their own
    /// "@..." token. `due` above always reports the earliest of these;
    /// this is what backs the "+N" badge next to the due pill (file list
    /// and title bar alike), so a note with several due dates doesn't
    /// quietly look like it only has the one soonest one.
    public var dueDateCount: Int { cache.activeDueDates.count }

    /// A whole checked task-list line — used with `NoteMarkup.dueRegex` /
    /// strikethrough to retire due tokens on completed tasks.
    fileprivate static let checkedTaskLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+][ \t]+)?\[[xX]\][ \t]+.*$"#, options: [.anchorsMatchLines]
    )

}

extension Note: Equatable {
    // Custom rather than synthesized: the cache is a pure function of
    // url/content, so comparing it too would be redundant work on top of
    // the fields that already fully determine equality.
    public static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.content == rhs.content && lhs.modifiedDate == rhs.modifiedDate
    }
}

/// Splits the inside of a `[[…]]` into the note it points at and the text a
/// reader sees.
///
/// Envy understands two pieces of Obsidian's link syntax:
///
///   `[[Note|Anything]]`   an alias — the target is `Note`, the reader sees
///                          `Anything`. Written this way so a link can sit
///                          inside a sentence without the filename
///                          interrupting it.
///   `[[Note#Heading]]`    a heading reference. Envy does not jump to the
///                          heading, but it does resolve the link to `Note`
///                          rather than treating the whole string as a title.
///
/// The second is deliberately partial. Handling it this far means notes
/// pasted in from Obsidian resolve, back-link and survive a rename instead of
/// breaking silently, and real heading support can be added later without a
/// migration — the stored text is already correct.
public enum WikiLink {
    public struct Parsed: Equatable {
        /// The note title to resolve. Never contains an alias or heading.
        public let target: String
        /// What the reader sees. Equals the raw body unless an alias is given.
        public let display: String
        /// Offset of the `|` within the body, when there is one — the styler
        /// needs it to collapse the target half out of view.
        public let aliasPipeOffset: Int?
    }

    public static func parse(_ body: String) -> Parsed {
        let pipeIndex = body.firstIndex(of: "|")
        let targetPart = pipeIndex.map { String(body[body.startIndex..<$0]) } ?? body
        // Everything from the first # is a heading reference, not part of the
        // note's name.
        let withoutHeading = targetPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let target = String(withoutHeading).trimmingCharacters(in: .whitespaces)

        let display: String
        if let pipeIndex {
            display = String(body[body.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)
        } else {
            // No alias: show it as written. For a heading reference that
            // includes the heading, which is honest — the link goes to the
            // note, and the reader can see which part was meant.
            display = body.trimmingCharacters(in: .whitespaces)
        }

        return Parsed(
            target: target,
            display: display.isEmpty ? target : display,
            aliasPipeOffset: pipeIndex.map { body.distance(from: body.startIndex, to: $0) }
        )
    }
}
