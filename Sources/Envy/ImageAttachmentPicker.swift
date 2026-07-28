import SwiftUI
import AppKit
import ImageIO

/// A floating panel that shows every image in the vault's `.attachments`
/// folder as a grid of thumbnails, so a picture can be inserted by sight —
/// which is what you need when the filenames are `Pasted image 3.png`. Shown
/// from the editor (⇧⌘I or right-click → Insert Image…); picking one calls back
/// with its filename, which the editor drops in as an `![[…]]` reference.
@MainActor
final class ImageAttachmentPicker {
    static let shared = ImageAttachmentPicker()
    private var panel: NSPanel?

    func present(images: [URL], on host: NSWindow?, onPick: @escaping (String) -> Void) {
        dismiss()
        let view = ImageAttachmentPickerView(
            images: images,
            onPick: { [weak self] name in self?.dismiss(); onPick(name) },
            onCancel: { [weak self] in self?.dismiss() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Insert Image"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        if let host {
            panel.setFrameOrigin(NSPoint(x: host.frame.midX - 240, y: host.frame.midY - 220))
        } else {
            panel.center()
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ImageAttachmentPickerView: View {
    let images: [URL]
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 12)]

    private var filtered: [URL] {
        guard !filter.isEmpty else { return images }
        return images.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter images\u{2026}", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    // Return inserts the first match — the quick path when you
                    // half-remember the name; otherwise click the picture.
                    .onSubmit { if let first = filtered.first { onPick(first.lastPathComponent) } }
            }
            .padding(10)
            Divider()

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(images.isEmpty ? "No images yet." : "No matches.").foregroundStyle(.secondary)
                    if images.isEmpty {
                        Text("Drag or paste a picture into a note first.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered, id: \.self) { url in
                            Button { onPick(url.lastPathComponent) } label: { cell(url) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .background(.regularMaterial)
        .onExitCommand { onCancel() }
        .onAppear { filterFocused = true }
    }

    @ViewBuilder
    private func cell(_ url: URL) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                if let thumb = AttachmentThumbnailCache.thumbnail(for: url) {
                    Image(nsImage: thumb).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            .frame(height: 84)
            Text(url.lastPathComponent)
                .font(.caption2).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        .help(url.lastPathComponent)
    }
}

/// Decodes a small thumbnail per attachment, once, straight from disk via
/// ImageIO — so opening the picker on a folder of full-size photos stays light
/// (no full-resolution decode, no re-decode on scroll).
@MainActor
private enum AttachmentThumbnailCache {
    private static var cache: [URL: NSImage] = [:]

    static func thumbnail(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        let image: NSImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            image = NSImage(contentsOf: url)   // fallback for anything ImageIO can't thumbnail
        }
        if let image { cache[url] = image }
        return image
    }
}
