import SwiftUI
import AppKit
import EnvyCore

// The note-list side of the split view: search field (with ghost-text
// completion and operator styling), sort header, the list itself, and the
// template-browsing rows that replace it during a "template:" query.
// Split out of ContentView.swift purely for file size/navigability — same
// type, zero behavior change.

// A dynamic resolver rather than one fixed color — needs to darken the
// outline in Light mode and lighten it in Dark mode, not blend a static
// NSColor the way searchFieldBackground below does (same reasoning:
// resolving inside the closure, at actual draw time, is what tracks
// appearance correctly). Top-level in this file (not a static on
// ContentView) because extensions can't hold static stored properties.
private let searchFieldBorderColor = NSColor(name: nil) { appearance in
    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return isDark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.28)
}

extension ContentView {
    var listPane: some View {
        listPaneBody
            // Vault-wide tag rename, launched from the tag browser's
            // right-click menu. A confirm step is right for a rename that
            // rewrites every note — unlike the inline color changes beside
            // it, this can't just be undone by re-picking.
            .alert("Rename Tag", isPresented: Binding(
                get: { tagRenameTarget != nil },
                set: { if !$0 { tagRenameTarget = nil } }
            )) {
                TextField("Tag name", text: $tagRenameText)
                Button("Cancel", role: .cancel) { tagRenameTarget = nil }
                Button("Rename") { commitTagRename() }
            } message: {
                if let old = tagRenameTarget {
                    Text("Rename #\(old) everywhere it appears in your notes. The tag on disk changes in every note that carries it.")
                }
            }
            // Renaming into an existing tag merges the two — a bigger deal
            // than a rename, so it gets its own deliberate confirmation.
            .alert("Merge Tags?", isPresented: Binding(
                get: { pendingTagMerge != nil },
                set: { if !$0 { pendingTagMerge = nil } }
            )) {
                Button("Cancel", role: .cancel) { pendingTagMerge = nil }
                Button("Merge") {
                    if let merge = pendingTagMerge { performTagRename(from: merge.old, to: merge.new) }
                    pendingTagMerge = nil
                }
            } message: {
                if let merge = pendingTagMerge {
                    Text("#\(merge.new) already exists. Every note tagged #\(merge.old) will become #\(merge.new), and the two will be one tag from then on. #\(merge.new) keeps its color.")
                }
            }
            // Folder rename, launched from the folder browser's right-click
            // menu — the folder twin of Rename Tag above.
            .alert("Rename Folder", isPresented: Binding(
                get: { folderRenameTarget != nil },
                set: { if !$0 { folderRenameTarget = nil } }
            )) {
                TextField("Folder name", text: $folderRenameText)
                Button("Cancel", role: .cancel) { folderRenameTarget = nil }
                Button("Rename") { commitFolderRename() }
            } message: {
                if let old = folderRenameTarget {
                    Text("Rename the folder \"\(old)\". Every note inside moves with it; titles, links, and colors are all preserved. Include a / to file it under another folder.")
                }
            }
            .alert("Rename Failed", isPresented: Binding(
                get: { folderRenameError != nil },
                set: { if !$0 { folderRenameError = nil } }
            )) {
                Button("OK", role: .cancel) { folderRenameError = nil }
            } message: {
                if let message = folderRenameError { Text(message) }
            }
    }

    private var listPaneBody: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                searchRow
                listSortHeader
            }
            // Opaque, not blurred — an exception to the rest of the window's
            // translucent backdrop so the search/sort chrome (and, via the
            // window's own opaque title bar, everything above it) reads as
            // one solid block instead of fading into whatever's behind it.
            // Deliberately NOT tinted by fileListBackgroundColor — that
            // setting is scoped to the scrollable notes below, not this
            // header, which stays looking like the rest of the window chrome.
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isTemplateQuery {
                            matchingTemplateRows
                        } else if isTrashQuery {
                            matchingTrashRows
                        } else if isTagBrowseQuery {
                            matchingTagRows
                        } else if isFolderBrowseQuery {
                            matchingFolderRows
                        } else {
                            ForEach(filteredNotes) { note in
                                noteRow(for: note)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: selectedID) { _, newValue in
                    if let newValue {
                        proxy.scrollTo(newValue)
                    }
                }
                // Every browse mode's arrow-key highlight scrolls into view
                // the same way the note selection does — without these, the
                // highlight could walk right off the visible area.
                .onChange(of: highlightedTemplateID) { _, v in if let v { proxy.scrollTo(v) } }
                .onChange(of: highlightedTrashID) { _, v in if let v { proxy.scrollTo(v) } }
                .onChange(of: highlightedTagName) { _, v in if let v { proxy.scrollTo(v) } }
                .onChange(of: highlightedFolderName) { _, v in if let v { proxy.scrollTo(v) } }
                // Makes the list itself a real stop for Focus Next/Previous
                // Area, not just something you tap into — arrow keys move the
                // selection the same as they do from the search box, and
                // Return drops straight into the editor.
                .focusable()
                // The system's own default focus ring would otherwise show up
                // here too, on top of the custom border below — and unlike
                // that border, it's drawn by AppKit itself, so it ignores the
                // fade entirely and just sits there permanently.
                .focusEffectDisabled()
                .focused($focusedField, equals: .list)
                .onKeyPress(keys: [.downArrow]) { press in
                    handleListArrowKey(delta: 1, shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(keys: [.upArrow]) { press in
                    handleListArrowKey(delta: -1, shiftHeld: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.return) {
                    // Browsing trash: never acts on its own — Restore/Delete
                    // are always an explicit button or right-click away, so
                    // Return here is intentionally a no-op rather than
                    // mirroring actOnHighlightedTemplate()'s create-on-Return.
                    if isTemplateQuery { actOnHighlightedTemplate() }
                    else if isTagBrowseQuery {
                        // Drill into the highlighted tag (top/most-used by
                        // default): fills tag:"name" and the list flips to
                        // that tag's notes, the picker step complete.
                        if let name = highlightedTagName ?? browserTagCounts.first?.name { searchByTag(name) }
                    }
                    else if isFolderBrowseQuery {
                        if let name = highlightedFolderName ?? subfolderCache.first { searchByFolder(name) }
                    }
                    else if !isTrashQuery { focusedField = .editor }
                    return .handled
                }
                .focusHighlight(
                    isFocused: focusedField == .list,
                    fadeOut: fadeFocusHighlight,
                    color: Color(nsColor: theme.resolvedFocusHighlightColor),
                    lineWidth: CGFloat(theme.focusHighlightThickness),
                    shape: Rectangle()
                )
            }
            .background(fileListBackground)
            // queryHasExactTitleMatch comes from the background search pass
            // rather than scanning every title here in the body on each
            // keystroke render — it trails typing by the debounce, which
            // for a hint pill is imperceptible.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && !isSearchOperatorQuery && !queryHasExactTitleMatch {
                // Folder-aware when the query reads as "Folder/Title" against
                // a real folder — the pill is the promise of what ⏎ does, so
                // it must say where the note will land.
                let creation = folderTargetedCreation(from: query.trimmingCharacters(in: .whitespaces))
                Text(creation.map { "Press \u{23CE} to create \"\($0.title)\" in \($0.folder)" }
                     ?? "Press \u{23CE} to create \"\(query)\"")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }

    /// One row in the regular (non-template, non-trash) note list. Pulled
    /// out of listPane's own body — that ForEach's row content, inline,
    /// pushed the whole already-large view body past the type checker's
    /// budget ("unable to type-check this expression in reasonable time"),
    /// the same class of problem FocusHighlight.swift's own split addressed
    /// for EditorViewNotifications.
    /// Rebuilds the cached folder state: the subfolder list for the move menu,
    /// the folder→color map for its swatches, and the note→color map for the
    /// list dots. One filesystem walk + one JSON decode, run only on real
    /// changes (reload, pref change, move, toggle) — never per row, which is
    /// what made a large vault crawl when this was computed inline.
    /// Everything — used on first appear and on the subfolder-scanning toggle,
    /// where the whole picture can change at once.
    func recomputeFolderState() {
        reloadSubfolderList()
        rebuildFolderColors()
        rebuildNoteFolderCaches()
    }

    /// The one expensive part — a filesystem walk of the Index for its
    /// subfolders. Only the folder *list* needs this, and it only changes when
    /// folders are added or removed, so this is kept off the per-note-change
    /// path (a move doesn't touch it; a new folder is added incrementally).
    func reloadSubfolderList() {
        subfolderCache = indexIncludeSubfolders ? NoteStore.subfolders(in: store.noteDirectory) : []
    }

    /// Cheap: decode the color pref and pre-render one menu swatch per colored
    /// folder. No filesystem, no note scan.
    func rebuildFolderColors() {
        guard indexIncludeSubfolders else { folderColorMap = [:]; folderSwatchCache = [:]; return }
        // Every folder is born colored, tag-style: any folder seen without a
        // color (newly created in Envy, made in Finder, or predating this
        // behavior) gets a random preset, persisted — so its dot, and the
        // dot's right-click recolor menu, always exist. Writing the pref
        // retriggers this via its own onChange; the second pass finds
        // nothing uncolored and settles.
        var all = FolderColorPreferences.loadAll(from: folderColorsRaw)
        var assigned = false
        for folder in subfolderCache where all[folder] == nil {
            if let preset = FolderColorPreferences.presets.randomElement() {
                all[folder] = CodableColor(nsColor: NSColor(preset.color))
                assigned = true
            }
        }
        if assigned { folderColorsRaw = FolderColorPreferences.encode(all) }
        folderColorMap = all.mapValues { $0.color }
        folderSwatchCache = folderColorMap.mapValues { Self.folderSwatch($0) }
    }

    /// One pass over notes (no filesystem): which subfolder each note is in (for
    /// the move menu's disabled "current folder") and its dot color (the colored
    /// subset). noteDirectory is already resolved and notes are enumerated from
    /// it, so a plain prefix compare matches without re-standardizing every URL.
    func rebuildNoteFolderCaches() {
        guard indexIncludeSubfolders else { noteSubfolderCache = [:]; noteFolderColorCache = [:]; return }
        let rootPrefix = store.noteDirectory.path + "/"
        var subs: [String: String] = [:]
        var colors: [String: Color] = [:]
        for note in store.notes {
            let parent = note.url.deletingLastPathComponent().path
            guard parent.hasPrefix(rootPrefix) else { continue }
            let relative = String(parent.dropFirst(rootPrefix.count))
            guard !relative.isEmpty, relative != NoteStore.inboxFolderName else { continue }
            subs[note.id] = relative
            if let color = folderColorMap[relative] { colors[note.id] = color }
        }
        noteSubfolderCache = subs
        noteFolderColorCache = colors
    }

    @ViewBuilder
    private func noteRow(for note: Note) -> some View {
        NoteRow(note: note, showPreview: showNotePreview, showDateModified: showDateModified, dateDisplayStyle: dateDisplayStyle, sortField: sortField, theme: theme, textColor: theme.fileListTextColor?.color, bold: boldFileListText, isPinned: isPinned(note), isFleeting: inboxNoteIDsCache.contains(note.id), folderColor: noteFolderColorCache[note.id], dotTrailing: noteDotTrailing, folderName: noteSubfolderCache[note.id], onFolderSearch: { searchByFolder($0) }, isFirstRow: note.id == filteredNotes.first?.id, folderDisplay: FolderListDisplay(rawValue: folderListDisplayRaw) ?? .dot)
            .padding(.vertical, listDensity.rowVerticalPadding)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected(note) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.shift) {
                    selectRange(to: note)
                } else if NSEvent.modifierFlags.contains(.command) {
                    toggleMultiSelect(note)
                } else {
                    selectSingle(note)
                }
            }
            .contextMenu {
                if fullSelection.count > 1 && fullSelection.contains(note.id) {
                    bulkContextMenuItems
                } else {
                    singleContextMenuItems(for: note)
                }
            }
            .id(note.id)
    }

    /// An opaque fill behind the note list, applying regardless of the blur
    /// strength setting — nil (the default, "no color") shows the window's
    /// own blur/solid backdrop through instead, same as before this setting
    /// existed.
    @ViewBuilder
    private var fileListBackground: some View {
        if let fileListColor = theme.fileListBackgroundColor {
            fileListColor.color
        } else {
            Color.clear
        }
    }

    private var searchField: some View {
        ZStack(alignment: .leading) {
            // The real field has to paint first (bottom of the stack) even
            // though its own text is invisible in the operator-styled case
            // below — its native text-selection highlight is part of that
            // same paint pass, and drawing it *above* the styled/ghost
            // overlay text would blot out the very characters a drag-select
            // is meant to highlight. Underneath, the highlight box still
            // shows through (nothing opaque covers it), it just no longer
            // covers the readable text on top of it.
            TextField("Search or Create Note", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * interfaceFontScale))
                .foregroundColor(isSearchOperatorQuery ? .clear : nil)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if let suggestionRemainder {
                Text("\(Text(query).foregroundColor(.clear))\(Text(suggestionRemainder).foregroundColor(.secondary))")
                    .font(.system(size: 13 * interfaceFontScale))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            // Only shown (and only makes the real field's own text invisible
            // above) once there's an actual recognized prefix — leaves the
            // common case of an empty field or a plain search completely
            // untouched, including the TextField's native placeholder.
            if isSearchOperatorQuery {
                styledQueryText
                    .font(.system(size: 13 * interfaceFontScale))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .focused($focusedField, equals: .search)
        .onKeyPress(keys: [.downArrow]) { press in
            handleListArrowKey(delta: 1, shiftHeld: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(keys: [.upArrow]) { press in
            handleListArrowKey(delta: -1, shiftHeld: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard suggestionRemainder != nil else { return .ignored }
            completeSuggestion()
            return .handled
        }
        // ⌥⌫ empties the omnibar outright. macOS would ordinarily delete the
        // previous word here, but the omnibar is a command line more than a
        // text field — you're usually abandoning a whole query, not editing
        // one — and ⌘⌫ is already Delete Note, which must not be shadowed by
        // anything that merely clears text.
        .onKeyPress(keys: [.delete]) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            guard !query.isEmpty else { return .handled }
            query = ""
            return .handled
        }
        .onSubmit { handleEnter() }
        .onChange(of: query) { _, _ in
            // Synchronous and undebounced, unlike the search pipeline below
            // — a fresh list has to be up before the template rows render
            // (createTemplate resets the query and expects its new file
            // highlighted immediately), and listing the small Templates/
            // folder once per keystroke is nothing next to the several
            // reads per *render* the cache replaced. Only ever fires while
            // a "template:" query is being typed; plain searches never
            // touch the disk here.
            if isTemplateQuery { refreshTemplates() }
            // Debounced rather than recomputed inline — with several
            // thousand notes even the fast path below is real work, and
            // running it synchronously on every single keystroke was
            // competing with the search field's own text-insertion
            // rendering for the same main-thread frame. 60ms is well under
            // the threshold where typing itself starts to feel delayed,
            // but coalesces anything faster than that (fast typing bursts,
            // rapid backspacing) into one recompute instead of many.
            // A browser drill-in (searchByTag/searchByFolder) already
            // recomputed and settled synchronously — running the debounced
            // pipeline again would just redo identical work 60ms later.
            if suppressNextQueryDebounce {
                suppressNextQueryDebounce = false
                return
            }
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                // The pipeline itself runs on a background task (see
                // recomputeFilteredNotes) — this await is just sequencing,
                // so the settle below reads the fresh results.
                await recomputeFilteredNotes()
                guard !Task.isCancelled else { return }
                settleAfterQueryChange()
            }
        }
        // A plain .glassEffect alone reads as barely-there against the
        // search/sort header's own opaque .windowBackgroundColor (see
        // listPane below) — this fill sits behind the glass so the search
        // field is reliably a touch lighter than its surroundings no matter
        // the appearance, blur setting, or file-list color customization,
        // none of which reach this deliberately opaque header area anyway.
        .background(Capsule().fill(searchFieldBackground))
        .glassEffect(.regular, in: Capsule())
        // A resting-state outline — without it the search field barely
        // reads as a distinct control against the header in Light mode,
        // where the lightened fill above and the header's own background
        // are close in value. .separatorColor (the system's own dynamic
        // divider color) was tried first but read as too faint; a fixed
        // black/white blend at a deliberately higher opacity, via the
        // dynamic-resolver-closure pattern, is more pronounced.
        .overlay(Capsule().strokeBorder(Color(nsColor: searchFieldBorderColor), lineWidth: 1.5))
        .focusHighlight(
            isFocused: focusedField == .search,
            fadeOut: fadeFocusHighlight,
            color: Color(nsColor: theme.resolvedFocusHighlightColor),
            lineWidth: CGFloat(theme.focusHighlightThickness),
            shape: Capsule()
        )
    }

    /// The search field and, when anything is waiting, the fleeting-note
    /// count beside it.
    private var searchRow: some View {
        HStack(spacing: 8) {
            // Strictly "something is waiting". With the inbox empty,
            // "inbox:" is just an operator that matches nothing — no
            // different from a tag: search with no hits — so there's nowhere
            // to go back *from*, and clearing the query is the ordinary way
            // out of any query.
            if inboxEnabled, fleetingCount > 0 { fleetingBadge }
            searchField
            if cameraEnabled { cameraBadge }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    /// A camera pill mirroring the fleeting badge, on the far side of the search
    /// field: press it to Take Photo or Scan Documents from an iPhone straight
    /// into a fresh note. The SwiftUI capsule is the look; a transparent AppKit
    /// requestor floats on top to drive Continuity Camera and hand back the
    /// captured images.
    private var cameraBadge: some View {
        ZStack {
            Image(systemName: "camera")
                // Sized down from the digit's 13pt: the camera glyph is wider,
                // so at 13 its width + padding pushed the pill past the circle
                // diameter, making it larger than the fleeting badge. At 11 it
                // fits inside searchControlDiameter, matching that pill exactly.
                .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(minWidth: searchControlDiameter, minHeight: searchControlDiameter)
                .background(Capsule().fill(searchFieldBackground))
                .glassEffect(.regular, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: searchFieldBorderColor), lineWidth: 1.5))
            ContinuityCaptureButton(store: { store }) { names in
                createNoteFromCapture(imageNames: names)
            }
        }
        .fixedSize()
        .help("New note from an iPhone photo or scan")
    }

    /// How many notes are sitting in Inbox/ — counted over every note
    /// rather than the filtered list, so the count is the size of the
    /// backlog and not of whatever happens to be on screen. Counted in the
    /// background search pass (see computeSearch) rather than here: as a
    /// computed property it was an O(notes) scan with per-note URL work,
    /// re-run on every listPane render — twice whenever the badge showed.
    var fleetingCount: Int { fleetingCountCache }

    /// The search field's own height, expressed the way the field builds it:
    /// one line of its font plus its vertical padding. Derived rather than
    /// a fixed number so the badge stays a circle at every Interface Text
    /// Size, instead of drifting into an oval at the extremes.
    private var searchControlDiameter: CGFloat { 15.6 * interfaceFontScale + 12 }

    /// The count of fleeting notes, as a circle matching the search field —
    /// same fill, same glass, same border, same height.
    ///
    /// This is the whole reason the inbox can be a filter rather than a mode:
    /// the notes stay out of the way, but the number doesn't, so a backlog
    /// can't quietly accumulate unseen. Hidden entirely at zero — an empty
    /// inbox is the goal state, and a "0" sitting there permanently would
    /// nag about nothing.
    private var fleetingBadge: some View {
        // The same control in two states rather than two controls: in the
        // inbox it's the way out, everywhere else it's the way in. One
        // position, one shape, and the button that got you somewhere is the
        // button that brings you back.
        Button {
            query = isInboxQuery ? "" : "inbox:"
            focusedField = .search
        } label: {
            Group {
                if isInboxQuery {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12 * interfaceFontScale, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(fleetingCount)")
                        .font(.system(size: 13 * interfaceFontScale, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: theme.resolvedDueSoonColor))
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: searchControlDiameter, minHeight: searchControlDiameter)
            .background(Capsule().fill(searchFieldBackground))
            .glassEffect(.regular, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: searchFieldBorderColor), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(badgeHelp)
    }

    private var badgeHelp: String {
        if isInboxQuery { return "Back to all notes" }
        return fleetingCount == 1
            ? "1 fleeting note waiting, click to review"
            : "\(fleetingCount) fleeting notes waiting, click to review"
    }

    /// A fixed step lighter than the header's own opaque background,
    /// blending toward white rather than picking an absolute light/dark
    /// color — the same fractional blend reads as "a bit lighter" correctly
    /// in both appearances, rather than needing a separate light-mode and
    /// dark-mode constant.
    ///
    /// Wrapped in a dynamic NSColor resolver rather than blending eagerly
    /// here — calling .blended(withFraction:of:) directly on a dynamic
    /// color like .windowBackgroundColor forces it to resolve to a fixed
    /// RGB snapshot immediately, using whatever appearance happens to be
    /// "current" at that exact moment. This property is a plain computed
    /// value evaluated during SwiftUI's render pass, not inside an actual
    /// AppKit drawing context, so that snapshot isn't reliably light-mode
    /// even when the window genuinely is — it showed up as a much-too-dark
    /// search bar in light mode. A resolver closure is only invoked by
    /// AppKit at actual draw time, with the correct appearance already
    /// active, so resolving .windowBackgroundColor and blending it inside
    /// the closure (not before it) is what actually tracks appearance
    /// correctly — same technique AeroSpaceInterop's menuBarOutlineColor
    /// already relies on.
    private var searchFieldBackground: Color {
        Color(nsColor: NSColor(name: nil) { _ in
            NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: .white) ?? NSColor.windowBackgroundColor
        })
    }

    private var listSortHeader: some View {
        HStack(spacing: 0) {
            sortHeaderButton(field: .name, label: "Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showDueSort {
                sortHeaderButton(field: .due, label: "Due")
                    .padding(.trailing, 12)
            }
            sortHeaderButton(field: .date, label: "Date")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func sortHeaderButton(field: NoteSortField, label: String) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortFieldRaw = field.rawValue
                sortAscending = field.defaultAscending
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9 * interfaceFontScale, weight: .bold))
                }
            }
            .font(.system(size: 11 * interfaceFontScale, weight: .semibold))
            .foregroundStyle(sortField == field ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Shown in place of the note list while "template:" is typed — click a
    /// row (or arrow through them) just opens it for editing, live and
    /// auto-saving, in the editor pane's own template branch — same
    /// click-to-open feel as a regular note, no separate "Edit Template"
    /// step. "Create Note from Template" is its own deliberate action now
    /// (Return, the button in the editor pane's header, or right-click),
    /// never a side effect of merely opening one to look at it. ⇧-click,
    /// ⌘-click, and ⇧↑/⇧↓ multi-select the same way the regular note list
    /// does, for bulk actions in the context menu.
    @ViewBuilder
    private var matchingTemplateRows: some View {
        ForEach(matchingTemplatesForQuery) { template in
            // .id so the ScrollViewReader can follow the arrow-key highlight
            // (ForEach identity alone isn't scrollTo-addressable).
            templateRow(for: template)
                .id(template.id)
        }
        if matchingTemplatesForQuery.isEmpty {
            if let fragment = templateNameFragment?.trimmingCharacters(in: .whitespaces), !fragment.isEmpty {
                Text("Press \u{23CE} to create template \"\(fragment)\"")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                Text("No templates yet. Type a name to create one.")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func templateRow(for template: NoteTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .foregroundStyle(.secondary)
            Text(template.name)
                .font(.system(size: 13 * interfaceFontScale))
            Spacer()
        }
        .padding(.vertical, listDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTemplateSelected(template) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                selectTemplateRange(to: template)
            } else if NSEvent.modifierFlags.contains(.command) {
                toggleMultiSelectTemplate(template)
            } else {
                selectSingleTemplate(template)
            }
        }
        .contextMenu {
            if fullTemplateSelection.count > 1 && fullTemplateSelection.contains(template.id) {
                bulkTemplateContextMenuItems
            } else {
                Button("Create Note from Template") {
                    createFromTemplate(template, title: template.name)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([template.url])
                }
                Button("Move Back to Notes List") {
                    convertTemplateToNote(template)
                }
                Button("Delete", role: .destructive) {
                    deleteTemplate(template)
                    // Deleting trashes the file without a store reload
                    // (deleteTemplate suppresses it) and without touching
                    // the query, so neither of the cache's automatic
                    // refresh triggers fires — refresh explicitly or the
                    // row lingers.
                    refreshTemplates()
                }
            }
        }
    }

    @ViewBuilder
    private var bulkTemplateContextMenuItems: some View {
        let templates = selectedTemplates()
        let count = templates.count
        Button("Create \(count) Notes from Templates") {
            for template in templates {
                createFromTemplate(template, title: template.name)
            }
        }
        Button("Reveal \(count) Templates in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(templates.map(\.url))
        }
        Button("Move \(count) Templates Back to Notes List") {
            for template in templates {
                convertTemplateToNote(template)
            }
            multiSelectedTemplateIDs.removeAll()
        }
        Button("Delete \(count) Templates", role: .destructive) {
            for template in templates {
                deleteTemplate(template)
            }
            multiSelectedTemplateIDs.removeAll()
            // Same reason as the single-template Delete: no reload, no
            // query change, so nothing else refreshes the cache.
            refreshTemplates()
        }
    }

    /// Shown in place of the note list while "trash:" is typed — click a row
    /// (or arrow keys) just browses, same as the regular note list; clicking
    /// never restores or deletes anything by itself. The highlighted note's
    /// content shows read-only in the editor pane (see trashPreviewPane), and
    /// Restore/Reveal/Delete are always a deliberate right-click or Return
    /// press away, never a side effect of merely looking at something.
    /// ⇧-click, ⌘-click, and ⇧↑/⇧↓ multi-select the same way the regular
    /// note list does.
    @ViewBuilder
    private var matchingTrashRows: some View {
        ForEach(matchingTrashForQuery) { note in
            trashRow(for: note)
                .id(note.id)   // scrollTo-addressable, same as template rows
        }
        if matchingTrashForQuery.isEmpty {
            Text("Trash is empty.")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    /// The tag catalog, shown when the query is a bare "tag:". Each tag as
    /// its own pill (color, tap-to-search, right-click-to-recolor all come
    /// from TagChipView, the same pill the title bar uses) with its note
    /// count, most-used first. Click or Return-on-highlight drills in.
    private var matchingTagRows: some View {
        let tags = browserTagCounts
        let active = highlightedTagName ?? tags.first?.name
        return Group {
            ForEach(tags, id: \.name) { entry in
                tagBrowseRow(name: entry.name, count: entry.count, highlighted: entry.name == active)
                    .id(entry.name)   // scrollTo-addressable for the arrow-key highlight
            }
            if tags.isEmpty {
                Text("No tags yet. Write #something in a note.")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func tagBrowseRow(name: String, count: Int, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            TagChipView(
                tag: name,
                theme: theme,
                onTagSearch: { searchByTag($0) },
                onRename: { beginTagRename($0) }
            )
            Spacer()
            Text("\(count)")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, listDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
        )
        .contentShape(Rectangle())
        // The pill's own tap wins on the pill; this catches the rest of the
        // row (the count, the gap) so the whole row is a target.
        .onTapGesture { searchByTag(name) }
    }

    /// The folder catalog, shown for a bare "folder:". Each folder as a
    /// colored dot (its own color) and relative path, with a direct note
    /// count, sorted like every other folder list (subfolderCache order).
    /// Gated on subfolder scanning, since folders don't exist without it.
    private var matchingFolderRows: some View {
        let counts = folderNoteCounts
        let active = highlightedFolderName ?? subfolderCache.first
        return Group {
            if !indexIncludeSubfolders {
                Text("Folders are off. Turn on Settings → General → \"Show items in subfolders.\"")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if subfolderCache.isEmpty {
                Text("No folders yet.")
                    .font(.system(size: 11 * interfaceFontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(subfolderCache, id: \.self) { folder in
                    folderBrowseRow(name: folder, count: counts[folder] ?? 0, highlighted: folder == active)
                        .id(folder)   // scrollTo-addressable for the arrow-key highlight
                }
            }
        }
    }

    @ViewBuilder
    private func folderBrowseRow(name: String, count: Int, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(folderColorMap[name] ?? Color.secondary)
                .frame(width: 8 * interfaceFontScale, height: 8 * interfaceFontScale)
            Text(name)
                .font(.system(size: 13 * interfaceFontScale))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, listDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { searchByFolder(name) }
        .contextMenu {
            FolderColorMenu(
                folderName: name,
                currentColor: folderColorMap[name],
                onRename: { beginFolderRename($0) }
            )
        }
    }

    @ViewBuilder
    private func trashRow(for note: Note) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(note.title)
                .font(.system(size: 13 * interfaceFontScale))
            Spacer()
            Text(dateDisplayStyle.format(note.modifiedDate))
                .font(.system(size: 11 * interfaceFontScale))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, listDensity.rowVerticalPadding)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTrashSelected(note) ? Color(nsColor: theme.resolvedSelectionColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                selectTrashRange(to: note)
            } else if NSEvent.modifierFlags.contains(.command) {
                toggleMultiSelectTrash(note)
            } else {
                selectSingleTrash(note)
            }
        }
        .contextMenu {
            if fullTrashSelection.count > 1 && fullTrashSelection.contains(note.id) {
                bulkTrashContextMenuItems
            } else {
                Button("Restore") {
                    restoreFromTrash(note)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([note.url])
                }
                Button("Delete", role: .destructive) {
                    deleteFromTrash(note)
                }
            }
        }
    }

    @ViewBuilder
    private var bulkTrashContextMenuItems: some View {
        let notes = selectedTrashNotes()
        let count = notes.count
        Button("Restore \(count) Notes") {
            for note in notes {
                restoreFromTrash(note)
            }
            multiSelectedTrashIDs.removeAll()
        }
        Button("Reveal \(count) Notes in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(notes.map(\.url))
        }
        Button("Delete \(count) Notes", role: .destructive) {
            for note in notes {
                deleteFromTrash(note)
            }
            multiSelectedTrashIDs.removeAll()
        }
    }

    // MARK: - Query interpretation

    /// True if any whitespace-separated word in the query is a recognized
    /// search operator — matches NoteStore.filtered(query:), which honors
    /// all of these anywhere in the query (combined with free-text terms
    /// and, since comma-separated groups were added, split across groups
    /// too — but this check works at the word level regardless of which
    /// comma group a word happens to be in, so nothing extra is needed
    /// here for that).
    private var containsSearchOperator: Bool {
        query.split(separator: " ").contains { Self.isSearchOperatorWord($0.lowercased()) }
    }

    /// The filter operators NoteStore.filtered(query:) recognizes, shared
    /// between containsSearchOperator and styledQueryText so the two can't
    /// drift apart again (they had, once each grew its own hand-written
    /// chain). Split prefix-matched from whole-word because that difference
    /// is load-bearing: "todo:xyz" is not an operator, "tag:xyz" is.
    private static let operatorPrefixes = ["tag:", "title:", "date:", "due:", "link:", "interlink:", "folder:", "stale:", "-link:", "-interlink:", "-folder:", "-tag:", "-title:"]
    private static let operatorWords = ["orphan:", "linked:", "todo:", "img:", "embed:", "ghost:"]

    /// Whether one lowercased query word reads as an operator.
    /// `browsePrefixes` exists because the two call sites deliberately
    /// differ: styledQueryText dims the browse-mode prefixes
    /// (template:/trash:/inbox:) too, since they're visibly commands, but
    /// containsSearchOperator must not match them — they aren't filters
    /// NoteStore.filtered honors mid-query, and isSearchOperatorQuery
    /// already accounts for them separately (whole-query, first-word-only).
    private static func isSearchOperatorWord(_ lowered: String, browsePrefixes: [String] = []) -> Bool {
        operatorPrefixes.contains(where: lowered.hasPrefix)
            || browsePrefixes.contains(where: lowered.hasPrefix)
            || operatorWords.contains(lowered)
            || (lowered.hasPrefix("-") && lowered.count > 1)
    }

    /// "tag:xyz"/"date:xyz" are search operators, not literal titles — Enter
    /// shouldn't offer (or fall back to) creating a note literally named
    /// after the whole query when one's present.
    var isSearchOperatorQuery: Bool {
        containsSearchOperator || isTemplateQuery || isTrashQuery || isInboxQuery
    }

    /// "template:xyz" — like tag:/date:, but a create action rather than a
    /// filter, so unlike them it only counts when it's the query's first
    /// word (not combinable mid-query) and drives creating a note from a
    /// template instead of filtering existing ones.
    var templateNameFragment: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("template:") else { return nil }
        return String(trimmed.dropFirst("template:".count))
    }

    var isTemplateQuery: Bool { templateNameFragment != nil }

    /// Templates whose name contains the typed fragment — an empty
    /// fragment (just "template:" typed so far) matches everything, same
    /// as tag:/date: showing everything until you narrow it.
    var matchingTemplatesForQuery: [NoteTemplate] {
        guard let fragment = templateNameFragment else { return [] }
        let needle = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return availableTemplates }
        return availableTemplates.filter { $0.name.lowercased().contains(needle) }
    }

    /// "trash:xyz" — browses every note currently sitting in one of The
    /// Index's `.trash` subfolders (see NoteStore.trashedNotes), same
    /// query-prefix shape as template:, so you can find, restore, or
    /// permanently delete a trashed note without leaving the search box.
    var trashNameFragment: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("trash:") else { return nil }
        return String(trimmed.dropFirst("trash:".count))
    }

    var isTrashQuery: Bool { trashNameFragment != nil }

    /// "inbox:xyz" — browses fleeting notes waiting in `Inbox/`, same
    /// query-prefix shape as template: and trash:. Unlike those two,
    /// pressing Return on an unmatched fragment *captures* it: the operator
    /// that scopes the box is the one that routes writing into it, so
    /// there's no separate create syntax to learn.
    var inboxNameFragment: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("inbox:") else { return nil }
        return String(trimmed.dropFirst("inbox:".count))
    }

    var isInboxQuery: Bool { inboxNameFragment != nil }

    /// A bare "tag:" (the operator with no argument) reveals the whole tag
    /// catalog in the list to pick from, the browsable form of the `tag:`
    /// ghost-text completion. The moment a character follows, it's the
    /// ordinary tag filter again, so this owns only the empty-argument
    /// state. The same "bare operator lists its own vocabulary" shape the
    /// browse prefixes (template:/trash:) already use.
    var isTagBrowseQuery: Bool {
        query.trimmingCharacters(in: .whitespaces).lowercased() == "tag:"
    }

    /// The `folder:` twin of isTagBrowseQuery — a bare "folder:" reveals the
    /// folder catalog to pick from, same bare-operator pattern.
    var isFolderBrowseQuery: Bool {
        query.trimmingCharacters(in: .whitespaces).lowercased() == "folder:"
    }

    /// Note count per folder as a drill-in counts them: the folder's own
    /// notes plus everything nested beneath it, matching folder:"..."'s
    /// exact-or-descendant rule — so the number a browser row shows is the
    /// number clicking it yields. Built off the cache the list already
    /// maintains.
    var folderNoteCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for path in noteSubfolderCache.values {
            counts[path, default: 0] += 1
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                counts[parent, default: 0] += 1
            }
        }
        return counts
    }

    /// The tag catalog's counts. Fast path is the store's cache; when the
    /// Inbox is hidden from the main list, its notes won't appear in a
    /// drill-in's results, so their tags are excluded from the counts too —
    /// the number you see is the number you get.
    var browserTagCounts: [(name: String, count: Int)] {
        if showInboxInMainList || fleetingCountCache == 0 { return store.tagCounts() }
        return NoteStore.tagCounts(in: store.notes.filter { !inboxNoteIDsCache.contains($0.id) })
    }

    /// Any query whose list shows something other than the notes themselves.
    /// While one of these is active a note selection still exists underneath
    /// (the browse pipelines don't clear it) but isn't what's on screen —
    /// note-level shortcuts (delete, pin) must not act on it invisibly.
    var isBrowseQuery: Bool {
        isTemplateQuery || isTrashQuery || isTagBrowseQuery || isFolderBrowseQuery
    }

    /// Everything that settles after the results caches are fresh for a new
    /// query — selection reconciled, every browse highlight cleared the
    /// moment its mode ends, and the editor's search-match highlighting
    /// caught up. One function shared by the debounced pipeline and the
    /// synchronous drill-in path (searchByTag/searchByFolder), so the two
    /// can't drift apart.
    func settleAfterQueryChange() {
        reconcileSelection()
        reconcileTemplateHighlight()
        reconcileTrashHighlight()
        // The tag/folder browsers' arrow-key highlight resets the moment
        // the query stops being that browser — same idea as the reconciles
        // above, so a later visit starts at the top instead of drilling
        // into a row remembered from last time.
        if !isTagBrowseQuery { highlightedTagName = nil }
        if !isFolderBrowseQuery { highlightedFolderName = nil }
        // See editorSearchQuery's declaration for why the editor never sees
        // the live per-keystroke query.
        editorSearchQuery = query
    }

    /// The fleeting notes currently listed — just the filtered list, since
    /// `inbox:` is a real search operator handled in NoteStore.filtered.
    /// Used for picking what to land on after a submit or delete.
    var matchingInboxForQuery: [Note] {
        filteredNotes.filter { store.isInboxNote($0) }
    }

    /// Trashed notes whose title contains the typed fragment — an empty
    /// fragment (just "trash:" typed so far) matches everything, same as
    /// template:'s own fragment filtering.
    var matchingTrashForQuery: [Note] {
        guard let fragment = trashNameFragment else { return [] }
        let needle = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return availableTrashedNotes }
        return availableTrashedNotes.filter { $0.lowercasedTitle.contains(needle) }
    }

    /// The typed query with every recognized operator word dimmed slightly,
    /// to acknowledge it's being read as a command rather than literal
    /// search text — whitespace is preserved exactly as typed, only the
    /// operator/non-operator words differ in styling. Rendered as an
    /// overlay in place of the search TextField's own (made-invisible) text
    /// — see searchField above.
    private var styledQueryText: Text {
        guard containsSearchOperator else { return Text(query) }
        var result = Text("")
        var index = query.startIndex
        while index < query.endIndex {
            if query[index] == " " {
                var end = index
                while end < query.endIndex, query[end] == " " { end = query.index(after: end) }
                result = Text("\(result)\(Text(query[index..<end]))")
                index = end
            } else {
                // Scan one token, but treat a quoted run as part of the same
                // token so an operator's multi-word argument (folder:"test
                // folder") stays glued to the operator and dims as a whole,
                // rather than the space inside the quotes splitting off a
                // second, undimmed word. An unbalanced opening quote (still
                // typing the argument) runs to the end, which is what we want.
                var end = index
                var inQuote = false
                while end < query.endIndex {
                    let ch = query[end]
                    if ch == "\"" { inQuote.toggle() }
                    else if ch == " ", !inQuote { break }
                    end = query.index(after: end)
                }
                let word = query[index..<end]
                let isOperator = Self.isSearchOperatorWord(word.lowercased(), browsePrefixes: ["template:", "trash:", "inbox:"])
                result = Text("\(result)\(Text(word).foregroundColor(isOperator ? Color.primary.opacity(0.8) : .primary))")
                index = end
            }
        }
        return result
    }

    /// The remainder of the cached suggestion (computed in the background
    /// search pass) beyond what's currently typed. Revalidated against the
    /// *live* query — the cache trails typing by the search debounce, so a
    /// character that breaks the prefix match hides the ghost text
    /// immediately instead of showing a stale completion, and a character
    /// that extends the same match shrinks the remainder without waiting.
    /// Tag completion (see tagSuggestionRemainder) takes priority whenever
    /// the query's last word is actually a tag: operator, since a note
    /// title match against the same text wouldn't mean anything there.
    private var suggestionRemainder: String? {
        if let tagRemainder = tagSuggestionRemainder { return tagRemainder }
        if let linkRemainder = linkSuggestionRemainder { return linkRemainder }
        if let folderRemainder = folderSuggestionRemainder { return folderRemainder }
        guard let note = suggestionNoteCache, !query.isEmpty,
              note.title.count > query.count,
              note.lowercasedTitle.hasPrefix(query.lowercased()) else { return nil }
        let startIndex = note.title.index(note.title.startIndex, offsetBy: query.count)
        return String(note.title[startIndex...])
    }

    /// Whichever operator prefix ("tag:" or "-tag:") the last word currently
    /// being typed starts with, if any, plus whatever's been typed after it
    /// — ghost-text always assumes you're typing at the very end of the
    /// query, same assumption the note-title suggestion above makes, so
    /// only the trailing word is considered, not tag: operators earlier in
    /// a multi-word query.
    private var tagCompletionContext: (prefix: String, fragment: String)? {
        guard let lastWord = query.split(separator: " ").last else { return nil }
        let lowered = lastWord.lowercased()
        for prefix in ["-tag:", "tag:"] {
            if lowered.hasPrefix(prefix) {
                return (prefix, String(lastWord.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    /// The link operator (link:/interlink:, either polarity) the query is
    /// currently completing an argument for, if any. Unlike the tag context,
    /// this can't just take the last space-split word — a title mid-typing
    /// inside an open quote (link:"Meeting No) contains spaces — so it finds
    /// the last operator occurrence that sits at a word boundary and treats
    /// everything after it as the argument. `head` is the untouched query
    /// before the operator, kept so acceptance can rebuild the whole string.
    /// A closed quote means the argument is already complete: no context.
    private var linkCompletionContext: (prefix: String, fragment: String, head: String)? {
        // title: completes from the same pool — it substring-matches rather
        // than needing the exact title, but the completion is still the
        // fastest way to land on the note you mean.
        quotedArgumentContext(prefixes: ["-interlink:", "interlink:", "-link:", "link:", "-title:", "title:"])
    }

    /// Same shape for folder: — its names can carry spaces and commas too.
    private var folderCompletionContext: (prefix: String, fragment: String, head: String)? {
        quotedArgumentContext(prefixes: ["-folder:", "folder:"])
    }

    private func quotedArgumentContext(prefixes: [String]) -> (prefix: String, fragment: String, head: String)? {
        var best: (start: String.Index, prefix: String)? = nil
        for prefix in prefixes {
            guard let range = query.range(of: prefix, options: [.backwards, .caseInsensitive]) else { continue }
            let atWordStart = range.lowerBound == query.startIndex
                || query[query.index(before: range.lowerBound)] == " "
            guard atWordStart else { continue }
            if best == nil || range.lowerBound > best!.start {
                best = (range.lowerBound, prefix)
            }
        }
        guard let best else { return nil }
        let head = String(query[..<best.start])
        var fragment = String(query[query.index(best.start, offsetBy: best.prefix.count)...])
        if fragment.hasPrefix("\"") {
            guard !fragment.dropFirst().contains("\"") else { return nil }
            fragment = String(fragment.dropFirst())
        } else if fragment.contains(" ") {
            // Unquoted spaces mean the tokenizer already split this into
            // separate terms — the argument ended at the first space.
            return nil
        }
        return (best.prefix, fragment, head)
    }

    /// link:/interlink: complete against note titles, most recently edited
    /// first (the same ranking the editor's [[ autocomplete uses) — and it
    /// matters more here than for tag:, since these operators match exact
    /// titles: a partial title finds nothing, so the ghost text is the
    /// difference between usable and a memory test.
    private var linkSuggestionRemainder: String? {
        guard let (_, fragment, _) = linkCompletionContext, !fragment.isEmpty else { return nil }
        let lowered = fragment.lowercased()
        guard let match = noteTitlesByRecencyCache.first(where: { $0.lowercased().hasPrefix(lowered) && $0.count > fragment.count }) else { return nil }
        return String(match.dropFirst(fragment.count))
    }

    /// folder: completes against the actual subfolder list (relative paths,
    /// so nested folders complete whole: folder:Proj → Projects/Work).
    private var folderSuggestionRemainder: String? {
        guard let (_, fragment, _) = folderCompletionContext, !fragment.isEmpty else { return nil }
        let lowered = fragment.lowercased()
        guard let match = subfolderCache.first(where: { $0.lowercased().hasPrefix(lowered) && $0.count > fragment.count }) else { return nil }
        return String(match.dropFirst(fragment.count))
    }

    /// "tag:xyz"/"-tag:xyz" — the tag-name equivalent of the note-title
    /// suggestion, completing against every tag used anywhere in The Index
    /// (see allTagsByFrequencyCache), most-used first when several share a
    /// prefix.
    private var tagSuggestionRemainder: String? {
        guard let (_, fragment) = tagCompletionContext, !fragment.isEmpty else { return nil }
        let lowered = fragment.lowercased()
        guard let match = allTagsByFrequencyCache.first(where: { $0.lowercased().hasPrefix(lowered) && $0.count > fragment.count }) else { return nil }
        return String(match.dropFirst(fragment.count))
    }

    /// Accepts whichever suggestion is currently showing (⇥/→) — replaces
    /// just the trailing word for a tag: completion (preserving any earlier
    /// words in a multi-word query), or the whole query for a note-title
    /// completion, matching how each kind of ghost text is displayed.
    func completeSuggestion() {
        if let (prefix, fragment) = tagCompletionContext, let remainder = tagSuggestionRemainder {
            var words = query.split(separator: " ").map(String.init)
            if !words.isEmpty {
                words[words.count - 1] = prefix + fragment + remainder
            }
            query = words.joined(separator: " ")
            return
        }
        if let (prefix, fragment, head) = linkCompletionContext, let remainder = linkSuggestionRemainder {
            // Quote the accepted title whenever it has spaces — the
            // tokenizer would otherwise split it into separate terms.
            let full = fragment + remainder
            let argument = full.contains(" ") ? "\"\(full)\"" : full
            query = head + prefix + argument
            return
        }
        if let (prefix, fragment, head) = folderCompletionContext, let remainder = folderSuggestionRemainder {
            let full = fragment + remainder
            let argument = full.contains(" ") ? "\"\(full)\"" : full
            query = head + prefix + argument
            return
        }
        if suggestionRemainder != nil, let note = suggestionNoteCache {
            query = note.title
        }
    }

    /// Column sort is authoritative over the list's order — it applies on
    /// top of (not instead of) the search filter, so typing still narrows
    /// down which notes show up, but the active column always decides the
    /// order they appear in, like Notational Velocity's Name/Date headers.
    /// Static over explicit parameters so the background search pipeline
    /// (ContentView.computeSearch) can run it off the main actor.
    nonisolated static func sortNotes(_ notes: [Note], field: NoteSortField, ascending: Bool) -> [Note] {
        switch field {
        case .name:
            return notes.sorted {
                let result = $0.title.localizedStandardCompare($1.title)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        case .date:
            return notes.sorted {
                ascending ? $0.modifiedDate < $1.modifiedDate : $0.modifiedDate > $1.modifiedDate
            }
        case .due:
            // A note with no due date always sorts to the end, regardless of
            // direction — "no due date" isn't smaller or larger than an
            // actual date, it's simply absent, and undated notes burying
            // dated ones (or vice versa) depending on which arrow is
            // clicked would be surprising either way.
            return notes.sorted {
                switch ($0.due, $1.due) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return ascending ? a < b : a > b
                }
            }
        }
    }

}
