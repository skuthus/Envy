import SwiftUI
import AppKit

struct ThemeSettingsView: View {
    @AppStorage("theme") private var theme = Theme()
    @AppStorage("backgroundBlurStrength") private var backgroundBlurStrengthRaw = BlurStrength.strong.rawValue
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @AppStorage("listDensity") private var listDensityRaw = ListDensity.compact.rawValue

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
            }

            Toggle("Use Custom Theme", isOn: $theme.isCustom)

            Section("Font") {
                Picker("Family", selection: $theme.fontName) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: $theme.fontSize, in: 10...28, step: 1)
                    Text("\(Int(theme.fontSize))pt")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .disabled(!theme.isCustom)

            Section("Window Background") {
                Picker("Blur Strength", selection: backgroundBlurStrength) {
                    ForEach(BlurStrength.allCases) { strength in
                        Text(strength.label).tag(strength)
                    }
                }
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

            Section {
                Text("Sample")
                    .font(.headline)
                previewText
                    .padding(10)
                    .background(theme.isCustom ? theme.backgroundColor.color : Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Button("Reset to Defaults") {
                theme = Theme()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var previewText: some View {
        let font = theme.isCustom
            ? Font.custom(theme.fontName, size: theme.fontSize)
            : Font.system(.body, design: .monospaced)
        let textColor = theme.isCustom ? theme.textColor.color : Color(nsColor: .labelColor)
        let markerColor = theme.isCustom ? theme.markerColor.color : Color(nsColor: .tertiaryLabelColor)
        let linkColor = theme.isCustom ? theme.linkColor.color : Color(nsColor: .linkColor)

        return (
            Text("# Heading\n").font(font).bold().foregroundStyle(textColor)
            + Text("this is ").font(font).foregroundStyle(textColor)
            + Text("**bold**").font(font).bold().foregroundStyle(markerColor)
            + Text(" and a ").font(font).foregroundStyle(textColor)
            + Text("[[wiki link]]").font(font).underline().foregroundStyle(linkColor)
        )
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
