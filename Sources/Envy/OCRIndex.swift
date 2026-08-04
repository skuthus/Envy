import Foundation
import AppKit
import EnvyCore

/// Coordinates on-device OCR of image attachments: recognition runs on a
/// utility queue, results are memoized to the content-hash cache so a repeat is
/// instant, and (from Slice 2) a name→text map is published for search. Never
/// blocks the main thread — recognition is background-only, per Envy's latency
/// rule.
@MainActor
final class OCRIndex: ObservableObject {
    static let shared = OCRIndex()

    private let queue = DispatchQueue(label: "app.envy.ocr", qos: .utility)

    /// Lowercased image filename → lowercased recognized text, for `img:`
    /// search. Rebuilt by `refresh`, nudged by `index`. Empty (nothing to
    /// search) until the first backfill lands or when OCR is turned off.
    @Published private(set) var searchText: [String: String] = [:]

    private var refreshing = false

    /// Settings → Editor → "Read text in images (OCR)". Default on.
    private var isEnabled: Bool { UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true }

    /// Background backfill: OCR every image attachment not already cached, then
    /// publish the name→text map search reads. A warm cache costs only a hash
    /// per image; only genuinely new images pay recognition. Runs on a utility
    /// queue and never blocks the main thread. Call on load and after a switch
    /// of index.
    func refresh(store: NoteStore) {
        guard isEnabled else { searchText = [:]; return }
        guard !refreshing else { return }
        refreshing = true
        let urls = store.imageAttachments()
        queue.async { [weak self] in
            var cache = OCRCache.load()
            var names: [String: String] = [:]
            var changed = false
            for url in urls {
                guard let hash = ImageOCR.contentHash(of: url) else { continue }
                let text: String
                if let hit = cache[hash] {
                    text = hit
                } else {
                    text = ImageOCR.recognizeText(in: url) ?? ""
                    cache[hash] = text
                    changed = true
                }
                if !text.isEmpty { names[url.lastPathComponent.lowercased()] = text.lowercased() }
            }
            if changed { OCRCache.save(cache) }
            Task { @MainActor in
                self?.searchText = names
                self?.refreshing = false
            }
        }
    }

    /// OCR a single freshly-added image (a capture, paste, or drop) and merge
    /// it into the search map — no full rescan, so inserting a picture stays
    /// cheap even in a large vault.
    func index(imageNamed name: String, store: NoteStore) {
        guard isEnabled,
              Note.imageAttachmentExtensions.contains((name as NSString).pathExtension.lowercased()) else { return }
        let url = store.attachmentURL(forName: name)
        queue.async { [weak self] in
            guard let hash = ImageOCR.contentHash(of: url) else { return }
            var cache = OCRCache.load()
            let text: String
            if let hit = cache[hash] {
                text = hit
            } else {
                text = ImageOCR.recognizeText(in: url) ?? ""
                cache[hash] = text
                OCRCache.save(cache)
            }
            guard !text.isEmpty else { return }
            let key = name.lowercased(), value = text.lowercased()
            Task { @MainActor in self?.searchText[key] = value }
        }
    }

    /// Recognizes the text of one image off the main thread, reading (and
    /// filling) the shared cache, then delivers it on the main actor. Used by
    /// "Copy Text from Image" — the user waits only the first time per image.
    func recognizedText(for url: URL, completion: @escaping @MainActor (String) -> Void) {
        queue.async {
            var cache = OCRCache.load()
            let text: String
            if let hash = ImageOCR.contentHash(of: url) {
                if let hit = cache[hash] {
                    text = hit
                } else {
                    text = ImageOCR.recognizeText(in: url) ?? ""
                    cache[hash] = text
                    OCRCache.save(cache)
                }
            } else {
                text = ImageOCR.recognizeText(in: url) ?? ""
            }
            Task { @MainActor in completion(text) }
        }
    }
}
