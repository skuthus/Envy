import Foundation

/// Converts the HTML that Apple Notes hands back over AppleScript into the
/// plain Markdown Envy stores on disk.
///
/// Deliberately a small hand-rolled scanner rather than NSAttributedString's
/// HTML importer: that one needs WebKit on the main thread, is nondeterministic
/// across OS versions, and would drag the whole import onto the UI thread —
/// exactly what the latency rule forbids. This is a pure function of its input,
/// which also makes it testable in SelfCheck without Apple Notes running.
///
/// It targets the specific, fairly clean HTML Notes emits — paragraphs as
/// `<div>`, `<b>/<i>`, `<ul>/<ol>/<li>`, `<h1..3>`, links, and checklists — and
/// isn't a general HTML-to-Markdown engine. Anything it doesn't recognise has
/// its tags stripped and its text kept, so unknown markup degrades to plain
/// text rather than leaking angle brackets into a note.
///
/// Images can't be reached over AppleScript (only a placeholder survives in the
/// body), so every `<img>`/`<object>` becomes an inline `[image omitted]` marker
/// — honest about what didn't come across instead of dropping it silently.
public enum NotesHTMLToMarkdown {

    public static func convert(_ html: String) -> String {
        var c = Converter()
        c.run(html)
        return c.finish()
    }

    /// Drops the note's title from the top of its own body.
    ///
    /// Apple Notes has no separate title field — a note's name *is* its first
    /// line, and that line is part of the body too. Since Envy's title is the
    /// filename, importing the body as-is repeats the title as line one. This
    /// removes that leading line when it matches the title, comparing on plain
    /// text so a styled title ("# Thoughts", "**Thoughts**") still matches the
    /// plain "Thoughts" that `name of note` returns. A body whose first line
    /// *isn't* the title (rare, but possible) is left untouched.
    public static func stripLeadingTitle(_ markdown: String, title: String) -> String {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        guard let firstIdx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return markdown }

        guard plainText(lines[firstIdx]).caseInsensitiveCompare(wanted) == .orderedSame else {
            return markdown
        }
        lines.removeSubrange(0...firstIdx)
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The visible text of a Markdown line, with heading (`#`) and emphasis
    /// (`*`, `_`) markers removed, for comparing a styled body line against a
    /// plain title.
    private static func plainText(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.replacingOccurrences(of: "**", with: "")
             .replacingOccurrences(of: "*", with: "")
             .replacingOccurrences(of: "_", with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private struct ListFrame {
        var ordered: Bool
        var checklist: Bool
        var counter: Int
    }

    private struct Converter {
        var out = ""
        var lists: [ListFrame] = []
        var anchors: [String?] = []   // pending <a> hrefs, nil = no href

        mutating func run(_ html: String) {
            let scalars = Array(html)
            var i = 0
            while i < scalars.count {
                let ch = scalars[i]
                if ch == "<" {
                    // Read to the matching '>'. Notes never nests '<' inside a
                    // tag, so a plain scan is safe.
                    var j = i + 1
                    while j < scalars.count && scalars[j] != ">" { j += 1 }
                    let raw = String(scalars[(i + 1)..<min(j, scalars.count)])
                    handleTag(raw)
                    i = j + 1
                } else {
                    // Accumulate a run of text up to the next tag, then decode
                    // entities once over the whole run.
                    var j = i
                    while j < scalars.count && scalars[j] != "<" { j += 1 }
                    appendText(decodeEntities(String(scalars[i..<j])))
                    i = j
                }
            }
        }

        // MARK: tags

        mutating func handleTag(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if trimmed.hasPrefix("!") { return }            // <!-- comments -->
            let closing = trimmed.hasPrefix("/")
            let inner = closing ? String(trimmed.dropFirst()) : trimmed
            let name = inner.prefix { $0.isLetter || $0.isNumber }.lowercased()
            let attrs = String(inner.dropFirst(name.count))

            switch name {
            case "br":
                out += "\n"
            case "div", "p":
                if closing { newlineBlock() }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if closing {
                    newlineBlock()
                } else {
                    ensureLineStart()
                    let level = Int(String(name.dropFirst())) ?? 1
                    out += String(repeating: "#", count: min(level, 6)) + " "
                }
            case "b", "strong":
                out += "**"
            case "i", "em":
                out += "_"
            case "u", "span", "font":
                break   // no Markdown equivalent; keep the text, drop the tag
            case "a":
                if closing {
                    let href = anchors.popLast() ?? nil
                    if let href, !href.isEmpty { out += "](\(href))" }
                } else {
                    let href = attribute("href", in: attrs)
                    anchors.append(href)
                    if let href, !href.isEmpty { out += "[" }
                }
            case "ul", "ol":
                if closing {
                    if !lists.isEmpty { lists.removeLast() }
                } else {
                    let isChecklist = attrs.lowercased().contains("checklist")
                    lists.append(ListFrame(ordered: name == "ol", checklist: isChecklist, counter: 1))
                }
            case "li":
                if !closing { openListItem(attrs) }
            case "img", "object":
                appendText("[image omitted]")
            default:
                break
            }
        }

        mutating func openListItem(_ attrs: String) {
            ensureLineStart()
            let depth = max(lists.count - 1, 0)
            out += String(repeating: "  ", count: depth)
            guard var frame = lists.last else { out += "- "; return }
            if frame.checklist || attrs.lowercased().contains("checklist") {
                // Notes rarely preserves the checked state over AppleScript, so
                // an item imports unchecked unless the markup explicitly says
                // otherwise — better an empty box you tick than a false done.
                let checked = attrs.lowercased().contains("checked")
                out += checked ? "- [x] " : "- [ ] "
            } else if frame.ordered {
                out += "\(frame.counter). "
                frame.counter += 1
                lists[lists.count - 1] = frame
            } else {
                out += "- "
            }
        }

        // MARK: text + spacing

        mutating func appendText(_ s: String) {
            guard !s.isEmpty else { return }
            out += s
        }

        /// End the current line without stacking blank lines — Notes wraps each
        /// paragraph in its own `<div>`, and nested divs would otherwise open a
        /// gap per level.
        mutating func newlineBlock() {
            if out.isEmpty { return }
            if !out.hasSuffix("\n") { out += "\n" }
        }

        mutating func ensureLineStart() {
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        }

        mutating func finish() -> String {
            // Collapse 3+ newlines to a single blank line, strip trailing
            // spaces per line, and trim the ends.
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            var result: [String] = []
            var blanks = 0
            for line in lines {
                if line.isEmpty {
                    blanks += 1
                    if blanks <= 1 { result.append("") }
                } else {
                    blanks = 0
                    result.append(line)
                }
            }
            return result.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - helpers

private func attribute(_ name: String, in attrs: String) -> String? {
    // Matches name="value" or name='value', case-insensitive on the key.
    guard let regex = try? NSRegularExpression(
        pattern: "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')",
        options: [.caseInsensitive]
    ) else { return nil }
    let range = NSRange(attrs.startIndex..., in: attrs)
    guard let m = regex.firstMatch(in: attrs, range: range) else { return nil }
    for g in 1...2 {
        if let r = Range(m.range(at: g), in: attrs) { return String(attrs[r]) }
    }
    return nil
}

private let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "trade": "™",
    "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
    "deg": "°", "middot": "·", "bull": "•", "times": "×", "divide": "÷",
]

private func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var result = ""
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
           s.distance(from: i, to: semi) <= 10 {
            let body = String(s[s.index(after: i)..<semi])
            if body.hasPrefix("#") {
                let numPart = body.dropFirst()
                let value: Int?
                if numPart.hasPrefix("x") || numPart.hasPrefix("X") {
                    value = Int(numPart.dropFirst(), radix: 16)
                } else {
                    value = Int(numPart)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar)); i = s.index(after: semi); continue
                }
            } else if let mapped = namedEntities[body] {
                result += mapped; i = s.index(after: semi); continue
            }
        }
        result.append(s[i]); i = s.index(after: i)
    }
    return result
}
