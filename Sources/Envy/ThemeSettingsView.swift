import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ThemeSettingsView: View {
    @AppStorage("theme") private var theme = Theme()
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage("listDensity") private var listDensityRaw = ListDensity.compact.rawValue
    @AppStorage("fadeFocusHighlight") private var fadeFocusHighlight = false
    @AppStorage("boldFileListText") private var boldFileListText = false
    @AppStorage("savedThemes") private var savedThemesStorage = SavedThemesList()
    // One-time migration so anyone with an existing custom theme from before
    // the gallery existed still sees it as a named, saved entry instead of
    // it only living invisibly in the single active `theme` slot.
    @AppStorage("didMigrateLegacyCustomTheme") private var didMigrateLegacyCustomTheme = false

    @State private var themeNamePrompt: ThemeNamePrompt?
    @State private var themeNameInput = ""
    @State private var importErrorMessage: String?
    @State private var themeToDelete: NamedTheme?

    private enum ThemeNamePrompt: Identifiable {
        case saveNew
        case rename(UUID)
        var id: String {
            switch self {
            case .saveNew: "saveNew"
            case .rename(let id): "rename-\(id.uuidString)"
            }
        }
    }

    private var listDensity: Binding<ListDensity> {
        Binding(
            get: { ListDensity(rawValue: listDensityRaw) ?? .compact },
            set: { listDensityRaw = $0.rawValue }
        )
    }

    private var backgroundBlurStrength: Binding<BlurStrength> {
        Binding(
            get: { BlurStrength(rawValue: backgroundBlurStrengthRaw) ?? .strong },
            set: { backgroundBlurStrengthRaw = $0.rawValue }
        )
    }

    /// Always editable, same as every other color now — nil ("no color")
    /// just means "hasn't been touched since Reset," restored via the
    /// swatch's own reset button (see colorSwatch's onReset) rather than a
    /// separate on/off toggle. Off, the note list keeps showing the
    /// window's own blur/solid backdrop through.
    private var fileListBackgroundColorBinding: Binding<Color> {
        Binding(
            get: { theme.fileListBackgroundColor?.color ?? Color(nsColor: .windowBackgroundColor) },
            set: { theme.fileListBackgroundColor = CodableColor(nsColor: NSColor($0)) }
        )
    }

    private var fileListTextColorBinding: Binding<Color> {
        Binding(
            get: { theme.fileListTextColor?.color ?? Color(nsColor: .labelColor) },
            set: { theme.fileListTextColor = CodableColor(nsColor: NSColor($0)) }
        )
    }

    /// Same reset-button-not-toggle pattern as the file list's own colors —
    /// nil keeps the note editor's title bar on the system's translucent
    /// .bar material.
    private var noteTitleBarBackgroundColorBinding: Binding<Color> {
        Binding(
            get: { theme.noteTitleBarBackgroundColor?.color ?? Color(nsColor: .windowBackgroundColor) },
            set: { theme.noteTitleBarBackgroundColor = CodableColor(nsColor: NSColor($0)) }
        )
    }

    private var noteTitleBarTextColorBinding: Binding<Color> {
        Binding(
            get: { theme.noteTitleBarTextColor?.color ?? Color(nsColor: .labelColor) },
            set: { theme.noteTitleBarTextColor = CodableColor(nsColor: NSColor($0)) }
        )
    }

    /// Same reset-button-not-toggle pattern as the file list/title bar
    /// colors above — nil tracks the system's live selection color instead
    /// of freezing a snapshot of it (see the comment on Theme.selectedTextColor
    /// for why baking that in eagerly broke selection highlighting).
    private var selectedTextColorBinding: Binding<Color> {
        Binding(
            get: { theme.selectedTextColor?.color ?? Color(nsColor: .selectedTextBackgroundColor) },
            set: { theme.selectedTextColor = CodableColor(nsColor: NSColor($0)) }
        )
    }

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { newValue in
                appearanceModeRaw = newValue.rawValue
                newValue.apply()
            }
        )
    }

    /// Called once, the first time this view appears after updating —
    /// carries an existing pre-gallery custom theme forward as a named,
    /// saved entry so it doesn't just silently vanish from view now that
    /// there's a gallery to show it in. The active `theme` itself was never
    /// at risk either way; this is purely about the gallery having
    /// something to show.
    private func migrateLegacyCustomThemeIfNeeded() {
        guard !didMigrateLegacyCustomTheme else { return }
        didMigrateLegacyCustomTheme = true
        guard theme.isCustom, !savedThemesStorage.themes.contains(where: { $0.name == "My Theme" }) else { return }
        savedThemesStorage.themes.append(NamedTheme(name: "My Theme", theme: theme))
    }

    private func applyTheme(_ candidate: Theme) {
        theme = candidate
    }

    private func saveCurrentAsNewTheme(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedThemesStorage.themes.append(NamedTheme(name: trimmed, theme: theme))
    }

    private func duplicate(_ named: NamedTheme) {
        savedThemesStorage.themes.append(NamedTheme(name: "\(named.name) Copy", theme: named.theme))
    }

    private func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedThemesStorage.themes.firstIndex(where: { $0.id == id }) else { return }
        savedThemesStorage.themes[index].name = trimmed
    }

    private func delete(_ id: UUID) {
        savedThemesStorage.themes.removeAll { $0.id == id }
    }

    /// Reuses NamedTheme's own Codable conformance (which itself round-trips
    /// Theme through its rawValue string — see Theme.swift) rather than
    /// inventing a separate export-only file format.
    private func export(_ named: NamedTheme) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(named.name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder().encode(named)
            try data.write(to: url)
        } catch {
            importErrorMessage = "Couldn't export \"\(named.name)\": \(error.localizedDescription)"
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            var imported = try JSONDecoder().decode(NamedTheme.self, from: data)
            // A fresh id — importing a theme someone exported from another
            // machine (or re-importing your own export) shouldn't collide
            // with an existing saved entry that happens to share the same id.
            imported.id = UUID()
            savedThemesStorage.themes.append(imported)
        } catch {
            importErrorMessage = "Couldn't import theme: \(error.localizedDescription)"
        }
    }

    private var fontFamilies: [String] {
        var families = Set(NSFontManager.shared.availableFontFamilies)
        // Guaranteed present regardless of whether NSFontManager enumerates it —
        // it's the app's default font, so it must always be selectable.
        families.insert("SF Pro Text")
        return families.sorted()
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Note List Density", selection: listDensity) {
                    ForEach(ListDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }
                Picker("Blur Strength", selection: backgroundBlurStrength) {
                    ForEach(BlurStrength.allCases) { strength in
                        Text(strength.label).tag(strength)
                    }
                }
            }

            Section("Focus Highlight") {
                Toggle("Fade out after a moment", isOn: $fadeFocusHighlight)
                HStack {
                    Text("Thickness")
                    Slider(value: $theme.focusHighlightThickness, in: 1...6, step: 1)
                    Text("\(Int(theme.focusHighlightThickness))pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }

            Section("Theme") {
                themeGallery
                HStack {
                    Button("Save Current as New Theme…") {
                        themeNameInput = ""
                        themeNamePrompt = .saveNew
                    }
                    Button("Import…", action: importTheme)
                }
            }

            Section("Font") {
                Picker("Family", selection: fontNameBinding) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: fontSizeBinding, in: 10...28, step: 1)
                    Text("\(Int(theme.fontSize))pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Section("Bold Text") {
                Toggle("Bold File List Text", isOn: $boldFileListText)
            }

            Section("Editor Colors") {
                colorGrid {
                    colorSwatch("Text", selection: customColorBinding(\.textColor))
                    colorSwatch("Background", selection: customColorBinding(\.backgroundColor))
                    colorSwatch("Markers", selection: customColorBinding(\.markerColor))
                    colorSwatch("Links", selection: customColorBinding(\.linkColor))
                    colorSwatch("Code Background", selection: customColorBinding(\.codeBackgroundColor))
                    colorSwatch("Tags", selection: customColorBinding(\.tagColor))
                    colorSwatch("Tag Background", selection: customColorBinding(\.tagBackgroundColor))
                    colorSwatch("Blockquotes", selection: customColorBinding(\.blockquoteColor))
                    colorSwatch("Completed Tasks", selection: customColorBinding(\.completedTaskColor))
                    colorSwatch("Footnotes", selection: customColorBinding(\.footnoteColor))
                    colorSwatch("Checked Checkbox", selection: customColorBinding(\.checkedCheckboxColor))
                }
            }

            Section("List Colors") {
                colorGrid {
                    colorSwatch(
                        "File List Background",
                        selection: fileListBackgroundColorBinding,
                        onReset: { theme.fileListBackgroundColor = nil },
                        isDefault: theme.fileListBackgroundColor == nil
                    )
                    colorSwatch(
                        "File List Text",
                        selection: fileListTextColorBinding,
                        onReset: { theme.fileListTextColor = nil },
                        isDefault: theme.fileListTextColor == nil
                    )
                    colorSwatch(
                        "File List Highlight Color",
                        selection: colorBinding(\.selectionColor),
                        onReset: { theme.selectionColor = Theme.defaultSelectionColor },
                        isDefault: theme.selectionColor == Theme.defaultSelectionColor
                    )
                    colorSwatch(
                        "Note Title Bar Background",
                        selection: noteTitleBarBackgroundColorBinding,
                        onReset: { theme.noteTitleBarBackgroundColor = nil },
                        isDefault: theme.noteTitleBarBackgroundColor == nil
                    )
                    colorSwatch(
                        "Note Title Bar Text",
                        selection: noteTitleBarTextColorBinding,
                        onReset: { theme.noteTitleBarTextColor = nil },
                        isDefault: theme.noteTitleBarTextColor == nil
                    )
                }
            }

            Section("Highlight Colors") {
                colorGrid {
                    colorSwatch("Search Highlight", selection: colorBinding(\.highlightColor))
                    colorSwatch(
                        "Focus Highlight",
                        selection: colorBinding(\.focusHighlightColor),
                        onReset: { theme.focusHighlightColor = Theme.defaultFocusHighlightColor },
                        isDefault: theme.focusHighlightColor == Theme.defaultFocusHighlightColor
                    )
                    colorSwatch(
                        "Text Selection",
                        selection: selectedTextColorBinding,
                        onReset: { theme.selectedTextColor = nil },
                        isDefault: theme.selectedTextColor == nil
                    )
                }
            }

            Section("Preview") {
                previewText
                    .padding(10)
                    .background(Color(nsColor: theme.resolvedBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Button("Reset to Defaults") {
                theme = Theme()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear(perform: migrateLegacyCustomThemeIfNeeded)
        .alert(
            themeNamePromptTitle,
            isPresented: Binding(
                get: { themeNamePrompt != nil },
                set: { if !$0 { themeNamePrompt = nil } }
            )
        ) {
            TextField("Name", text: $themeNameInput)
            Button(themeNamePromptActionTitle) {
                switch themeNamePrompt {
                case .saveNew: saveCurrentAsNewTheme(named: themeNameInput)
                case .rename(let id): rename(id, to: themeNameInput)
                case nil: break
                }
                themeNamePrompt = nil
            }
            Button("Cancel", role: .cancel) { themeNamePrompt = nil }
        }
        .alert(
            "Theme Import/Export",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \"\(themeToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { themeToDelete != nil },
                set: { if !$0 { themeToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = themeToDelete?.id { delete(id) }
                themeToDelete = nil
            }
            Button("Cancel", role: .cancel) { themeToDelete = nil }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var themeNamePromptTitle: String {
        switch themeNamePrompt {
        case .saveNew: "Save Current as New Theme"
        case .rename: "Rename Theme"
        case nil: ""
        }
    }

    private var themeNamePromptActionTitle: String {
        switch themeNamePrompt {
        case .saveNew: "Save"
        case .rename: "Rename"
        case nil: ""
        }
    }

    private struct GalleryEntry: Identifiable {
        let id: String
        let name: String
        let theme: Theme
        // Only set for a user-saved theme — gates the full rename/duplicate/
        // delete context menu, which built-in presets and System Default
        // don't get (presets are read-only; System Default is just "off").
        let namedTheme: NamedTheme?
    }

    private var galleryEntries: [GalleryEntry] {
        var entries = [GalleryEntry(id: "system-default", name: "System Default", theme: Theme(), namedTheme: nil)]
        entries += Theme.presets.map { GalleryEntry(id: $0.id.uuidString, name: $0.name, theme: $0.theme, namedTheme: nil) }
        entries += savedThemesStorage.themes.map { GalleryEntry(id: $0.id.uuidString, name: $0.name, theme: $0.theme, namedTheme: $0) }
        return entries
    }

    private var themeGallery: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
            ForEach(galleryEntries) { entry in
                themeSwatch(entry)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func themeSwatch(_ entry: GalleryEntry) -> some View {
        let isSelected = entry.id == "system-default" ? !theme.isCustom : theme == entry.theme
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: entry.theme.resolvedBackgroundColor))
                    .frame(width: 64, height: 44)
                    .overlay(
                        Text("Aa")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(nsColor: entry.theme.resolvedTextColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                    )
                HStack(spacing: 3) {
                    Circle().fill(Color(nsColor: entry.theme.resolvedLinkColor)).frame(width: 6, height: 6)
                    Circle().fill(Color(nsColor: entry.theme.resolvedTagColor)).frame(width: 6, height: 6)
                }
                .padding(4)
            }
            Text(entry.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 68)
        }
        .contentShape(Rectangle())
        .onTapGesture { applyTheme(entry.theme) }
        .contextMenu {
            if let named = entry.namedTheme {
                Button("Export…") { export(named) }
                Button("Duplicate") { duplicate(named) }
                Button("Rename…") {
                    themeNameInput = named.name
                    themeNamePrompt = .rename(named.id)
                }
                Button("Delete…", role: .destructive) { themeToDelete = named }
            } else if entry.id != "system-default" {
                Button("Export…") { export(NamedTheme(name: entry.name, theme: entry.theme)) }
                Button("Duplicate as My Theme") { duplicate(NamedTheme(name: entry.name, theme: entry.theme)) }
            }
        }
    }

    // Mirrors MarkdownStyler's actual rules rather than approximating them:
    // markers (#, **, *, `, [[ ]]) always stay in the marker color while only
    // the content between them picks up bold/italic/mono/link styling — the
    // marker characters themselves are never bolded or tinted with the
    // content's own color, unlike a naive "style the whole token" preview.
    private var previewText: some View {
        let font = Font(theme.resolvedFont as CTFont)
        // Matches the h1 case of the real heading-size formula (base + 9 for
        // a single "#") so the preview's scale isn't just a guess.
        let headingFont = Font(NSFontManager.shared.convert(theme.resolvedFont, toSize: theme.resolvedFont.pointSize + 9) as CTFont)
        let codeFont = Font.system(size: theme.resolvedFont.pointSize, design: .monospaced)
        let textColor = Color(nsColor: theme.resolvedTextColor)
        let markerColor = Color(nsColor: theme.resolvedMarkerColor)
        let linkColor = Color(nsColor: theme.resolvedLinkColor)
        let codeBackground = Color(nsColor: theme.resolvedCodeBackgroundColor)
        let tagColor = Color(nsColor: theme.resolvedTagColor)
        let tagBackground = Color(nsColor: theme.resolvedTagBackgroundColor)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("# ").foregroundStyle(markerColor)
                Text("Heading").font(headingFont).bold().foregroundStyle(textColor)
            }
            .font(font)

            HStack(spacing: 0) {
                Text("This is ").foregroundStyle(textColor)
                Text("**").foregroundStyle(markerColor)
                Text("bold").bold().foregroundStyle(textColor)
                Text("**").foregroundStyle(markerColor)
                Text(", ").foregroundStyle(textColor)
                Text("*").foregroundStyle(markerColor)
                Text("italic").italic().foregroundStyle(textColor)
                Text("*").foregroundStyle(markerColor)
                Text(", and ").foregroundStyle(textColor)
                Text("`").foregroundStyle(markerColor)
                Text("code").font(codeFont).foregroundStyle(textColor)
                    .padding(.horizontal, 2)
                    .background(codeBackground)
                Text("`").foregroundStyle(markerColor)
            }
            .font(font)

            HStack(spacing: 0) {
                Text("A ").foregroundStyle(textColor)
                Text("[[").foregroundStyle(markerColor)
                Text("wiki link").underline().foregroundStyle(linkColor)
                Text("]]").foregroundStyle(markerColor)
            }
            .font(font)

            HStack(spacing: 0) {
                Text("A ").foregroundStyle(textColor)
                Text("#tag").bold().foregroundStyle(tagColor)
                    .padding(.horizontal, 4)
                    .background(tagBackground)
            }
            .font(font)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Theme, CodableColor>) -> Binding<Color> {
        Binding(
            get: { theme[keyPath: keyPath].color },
            set: { theme[keyPath: keyPath] = CodableColor(nsColor: NSColor($0)) }
        )
    }

    /// Same as colorBinding, but also flips isCustom on. isCustom no longer
    /// has a visible toggle in the UI — every Editor Colors swatch (and the
    /// Font controls) is always editable, and touching any one of them is
    /// what quietly turns "custom" on instead of a separate switch the user
    /// had to remember to flip first. Kept as an internal flag rather than
    /// removed outright: resolvedTextColor and friends still need it to
    /// tell "the user picked System Default and hasn't touched a color"
    /// (return the live, appearance-tracking system color) apart from "the
    /// user picked/edited a real color" (return the frozen stored one) —
    /// without it, System Default would freeze at whatever it resolved to
    /// once, and stop following System/Light/Dark switches.
    private func customColorBinding(_ keyPath: WritableKeyPath<Theme, CodableColor>) -> Binding<Color> {
        Binding(
            get: { theme[keyPath: keyPath].color },
            set: { newValue in
                theme.isCustom = true
                theme[keyPath: keyPath] = CodableColor(nsColor: NSColor(newValue))
            }
        )
    }

    private var fontNameBinding: Binding<String> {
        Binding(
            get: { theme.fontName },
            set: { theme.isCustom = true; theme.fontName = $0 }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { theme.fontSize },
            set: { theme.isCustom = true; theme.fontSize = $0 }
        )
    }

    /// Shared two-column grid layout for every colorSwatch group — factored
    /// out once the color list grew past one flat section into Editor/
    /// List/Highlight groups, so each group doesn't repeat the same column
    /// spec.
    private func colorGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(minimum: 160), alignment: .leading), GridItem(.flexible(minimum: 160), alignment: .leading)], spacing: 12) {
            content()
        }
        .padding(.vertical, 4)
    }

    /// A compact swatch + label pairing, laid out several to a row in a
    /// grid instead of the one-ColorPicker-per-row layout Form gives by
    /// default (which left most of each row's width empty).
    @ViewBuilder
    private func colorSwatch(
        _ label: String,
        selection: Binding<Color>,
        onReset: (() -> Void)? = nil,
        isDefault: Bool = true
    ) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: selection)
                .labelsHidden()
            Text(label)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let onReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isDefault ? 0.35 : 1)
                .disabled(isDefault)
                .help("Reset to default")
            }
        }
    }
}
