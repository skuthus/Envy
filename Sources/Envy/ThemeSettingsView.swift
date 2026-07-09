import SwiftUI
import AppKit

struct ThemeSettingsView: View {
    @AppStorage("theme") private var theme = Theme()
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage("listDensity") private var listDensityRaw = ListDensity.compact.rawValue
    @AppStorage("fadeFocusHighlight") private var fadeFocusHighlight = false

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

    private var appearanceMode: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { newValue in
                appearanceModeRaw = newValue.rawValue
                newValue.apply()
            }
        )
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
                colorSwatch(
                    "Color",
                    selection: colorBinding(\.focusHighlightColor),
                    onReset: { theme.focusHighlightColor = Theme.defaultFocusHighlightColor },
                    isDefault: theme.focusHighlightColor == Theme.defaultFocusHighlightColor
                )
                HStack {
                    Text("Thickness")
                    Slider(value: $theme.focusHighlightThickness, in: 1...6, step: 1)
                    Text("\(Int(theme.focusHighlightThickness))pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }

            Section("Custom Theme") {
                Toggle("Use Custom Theme", isOn: $theme.isCustom)
                Picker("Family", selection: $theme.fontName) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .disabled(!theme.isCustom)
                HStack {
                    Text("Size")
                    Slider(value: $theme.fontSize, in: 10...28, step: 1)
                    Text("\(Int(theme.fontSize))pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .disabled(!theme.isCustom)
            }

            Section("Colors") {
                LazyVGrid(columns: [GridItem(.flexible(minimum: 160), alignment: .leading), GridItem(.flexible(minimum: 160), alignment: .leading)], spacing: 12) {
                    colorSwatch("Text", selection: colorBinding(\.textColor))
                        .disabled(!theme.isCustom)
                    colorSwatch("Background", selection: colorBinding(\.backgroundColor))
                        .disabled(!theme.isCustom)
                    colorSwatch("Markers", selection: colorBinding(\.markerColor))
                        .disabled(!theme.isCustom)
                    colorSwatch("Links", selection: colorBinding(\.linkColor))
                        .disabled(!theme.isCustom)
                    colorSwatch("Code Background", selection: colorBinding(\.codeBackgroundColor))
                        .disabled(!theme.isCustom)
                    colorSwatch("Search Highlight", selection: colorBinding(\.highlightColor))
                    colorSwatch(
                        "File List Highlight Color",
                        selection: colorBinding(\.selectionColor),
                        onReset: { theme.selectionColor = Theme.defaultSelectionColor },
                        isDefault: theme.selectionColor == Theme.defaultSelectionColor
                    )
                }
                .padding(.vertical, 4)
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
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Theme, CodableColor>) -> Binding<Color> {
        Binding(
            get: { theme[keyPath: keyPath].color },
            set: { theme[keyPath: keyPath] = CodableColor(nsColor: NSColor($0)) }
        )
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
