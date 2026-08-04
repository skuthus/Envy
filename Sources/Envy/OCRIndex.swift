import Foundation
import AppKit
import VisionKit
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
    /// The Attachments folder's modification date at the last backfill, per
    /// index. The dir's mtime changes only when a file is added or removed (our
    /// images are content-named and never rewritten), so an unchanged mtime means
    /// a rescan+rehash would find nothing new — skip it. Keeps repeated onAppear
    /// backfills from re-hashing every attachment.
    private var lastBackfillMTime: [String: Date] = [:]

    /// Settings → Editor → "Read text in images (OCR)". Default on.
    private var isEnabled: Bool { UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true }

    // MARK: - Shared per-image caches (word boxes + Live Text)

    /// One analyzer for every attachment view — stateless and meant to be reused.
    private static let analyzer = ImageAnalyzer()
    /// url.path → recognized words (for search-match highlighting), and
    /// url.path → Live Text analysis, both shared across attachment views so a
    /// note switch (or a second view of the same image) never re-recognizes.
    /// Bounded, oldest-evicted, since analyses aren't tiny.
    private var wordCache = KeyedCache<[ImageOCR.OCRWord]>(cap: 48)
    private var analysisCache = KeyedCache<ImageAnalysis>(cap: 24)

    /// Recognized word boxes for an image, off the main thread and shared: the
    /// first request recognizes, the rest (other views, note switches) are
    /// instant. Backs the `img:` highlight.
    func recognizeWords(for url: URL, completion: @escaping @MainActor ([ImageOCR.OCRWord]) -> Void) {
        if let cached = wordCache.value(url.path) { completion(cached); return }
        queue.async { [weak self] in
            let words = ImageOCR.recognizeWords(in: url)
            Task { @MainActor in
                self?.wordCache.set(url.path, words)
                completion(words)
            }
        }
    }

    /// VisionKit Live Text analysis for an image, shared and cached so it runs at
    /// most once per image per session. Lazy by caller (only when hovered), so an
    /// image you never touch costs nothing. nil if analysis fails.
    func liveTextAnalysis(for url: URL) async -> ImageAnalysis? {
        if let cached = analysisCache.value(url.path) { return cached }
        let configuration = ImageAnalyzer.Configuration([.text])
        guard let analysis = try? await Self.analyzer.analyze(imageAt: url, orientation: .up, configuration: configuration)
        else { return nil }
        analysisCache.set(url.path, analysis)
        return analysis
    }

    /// Background backfill: OCR every image attachment not already cached, then
    /// publish the name→text map search reads. A warm cache costs only a hash
    /// per image; only genuinely new images pay recognition. Runs on a utility
    /// queue and never blocks the main thread. Call on load and after a switch
    /// of index.
    func refresh(store: NoteStore) {
        guard isEnabled else { searchText = [:]; return }
        guard !refreshing else { return }
        // Skip a rescan when the Attachments folder hasn't changed since the last
        // backfill for this index (and we already have results to show).
        let attachmentsDir = store.attachmentsDirectory
        let mtime = (try? attachmentsDir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let mtime, lastBackfillMTime[attachmentsDir.path] == mtime, !searchText.isEmpty { return }
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
                if let mtime { self?.lastBackfillMTime[attachmentsDir.path] = mtime }
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

/// A tiny bounded cache: insertion-ordered, evicting the oldest past `cap`.
/// Main-actor confined (it only ever runs on OCRIndex), so no locking.
@MainActor
private struct KeyedCache<Value> {
    let cap: Int
    private var storage: [String: Value] = [:]
    private var order: [String] = []

    init(cap: Int) { self.cap = cap }

    func value(_ key: String) -> Value? { storage[key] }

    mutating func set(_ key: String, _ value: Value) {
        if storage[key] == nil { order.append(key) }
        storage[key] = value
        while order.count > cap {
            let oldest = order.removeFirst()
            storage[oldest] = nil
        }
    }
}
