import Foundation

/// Shared markdown-token patterns used by EnvyCore (search / derived fields)
/// and by MarkdownStyler in the app target. Keeping one definition prevents
/// `tag:` / due chips / wiki links / embeds from drifting apart from what
/// the editor paints.
public enum NoteMarkup {
    /// `#tag` body in capture group 1. Lookbehind skips mid-word and `##`.
    public static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\w#])#([A-Za-z0-9_-]+)"#)

    /// `[[…]]` target body in capture group 1 (also matches inside `![[…]]`).
    public static let wikiLinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]]+)\]\]"#)

    /// `![[…]]` embed inner in capture group 1.
    public static let embedRegex = try! NSRegularExpression(pattern: #"!\[\[([^\[\]]+)\]\]"#)

    /// Due token `@today` / `@monday` / `@04-16-26` — day name or date-shaped
    /// characters only, so `@mentions` and trailing commas stay out.
    public static let dueRegex = try! NSRegularExpression(
        pattern: #"(?<![\w])@(today|tomorrow|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday|[0-9/-]+)(?!\w)"#,
        options: [.caseInsensitive]
    )

    /// `~~struck~~` inner in capture group 1 — used to retire due tokens.
    public static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~([^~\n]+)~~"#)

    /// AI provenance line start; capture group 1 is `created` or `edited`.
    public static let aiSignatureRegex = try! NSRegularExpression(
        pattern: #"^⎈[ \t]+(created|edited)\b"#, options: [.anchorsMatchLines]
    )

    /// Whole AI provenance line (glyph through end of line) for editor
    /// protection / restore.
    public static let aiSignatureLineRegex = try! NSRegularExpression(
        pattern: #"^⎈[ \t]+(?:created|edited)\b.*$"#, options: [.anchorsMatchLines]
    )
}
