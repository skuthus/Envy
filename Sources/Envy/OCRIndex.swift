import Foundation
import AppKit
import VisionKit
import EnvyCore

/// Coordinates on-device OCR of image attachments: recognition runs on a serial
/// utility queue, results are memoized to the content-hash cache so a repeat is
/// instant, and a name→text map is published for search. Never blocks the main
/// thread — recognition is background-only, per Envy's latency rule.
@MainActor
final class OCRIndex: ObservableObject {
    static let shared = OCRIndex()

    private let queue = DispatchQueue(label: "app.envy.ocr", qos: .utility)

    /// Lowercased image filename → lowercased recognized text, for `img:`
    /// search. Rebuilt by `refresh`, nudged by `index`. Empty (nothing to
    /// search) until the first backfill lands or when OCR is turned off.
    @Published private(set) var searchText: [String: String] = [:]

    private var refreshing = false
    /// The Attachments folder's modification date at the last *completed*
    /// backfill, per index. The dir's mtime changes when an attachment is added
    /// or removed; our images are base-named (with a dedup counter) and never
    /// rewritten in place, so an unchanged mtime means a rescan would find
    /// nothing new — skip it, even when the last backfill produced no text.
    /// Presence of an entry *is* the "already backfilled at this mtime" flag.
    private var lastBackfillMTime: [String: Date] = [:]

    /// Settings → Editor → "Read text in images (OCR)". Default on.
    private var isEnabled: Bool { UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true }

    // MARK: - Disk cache (content-hash → text), memoized on the serial queue

    /// The on-disk cache held in memory so single-image OCR and backfills don't
    /// re-read the whole JSON each time. Touched ONLY inside `queue.async`
    /// blocks, which are serial, so a plain var is race-free there.
    nonisolated(unsafe) private var diskCache: [String: String]?

    nonisolated private func cacheOnQueue() -> [String: String] {
        if let diskCache { return diskCache }
        let loaded = OCRCache.load()
        diskCache = loaded
        return loaded
    }

    nonisolated private func persistOnQueue(_ cache: [String: String]) {
        diskCache = cache
        OCRCache.save(cache)
    }

    // MARK: - Shared per-image caches (word boxes + Live Text)

    private static let analyzer = ImageAnalyzer()
    /// url.path → recognized words (search-match highlighting) and → Live Text
    /// analysis, shared across attachment views so a note switch (or a second
    /// view of the same image) never re-recognizes. Bounded, oldest-evicted.
    private var wordCache = KeyedCache<[ImageOCR.OCRWord]>(cap: 48)
    private var analysisCache = KeyedCache<ImageAnalysis>(cap: 24)
    /// In-flight de-dup for word recognition: concurrent first-requests for the
    /// same image share one recognition instead of each doing the full work.
    /// (Live Text analysis isn't de-duped this way — ImageAnalysis isn't
    /// Sendable, so it can't cross a Task boundary; a rare double-analysis on
    /// simultaneous first hover is harmless.)
    private var wordsInFlight: [String: [@MainActor ([ImageOCR.OCRWord]) -> Void]] = [:]

    /// Recognized word boxes for an image, off the main thread and shared: the
    /// first request recognizes, the rest (other views, note switches, or a
    /// concurrent second caller) reuse it. Backs the `img:` highlight.
    func recognizeWords(for url: URL, completion: @escaping @MainActor ([ImageOCR.OCRWord]) -> Void) {
        let key = url.path
        if let cached = wordCache.value(key) { completion(cached); return }
        if wordsInFlight[key] != nil { wordsInFlight[key]?.append(completion); return }
        wordsInFlight[key] = [completion]
        queue.async { [weak self] in
            let words = ImageOCR.recognizeWords(in: url)
            Task { @MainActor in
                guard let self else { return }
                self.wordCache.set(key, words)
                let waiters = self.wordsInFlight.removeValue(forKey: key) ?? []
                for waiter in waiters { waiter(words) }
            }
        }
    }

    /// VisionKit Live Text analysis for an image, shared and cached so it runs at
    /// most once per image per session (concurrent first-callers share the same
    /// task). Lazy by caller (only when hovered), so an image you never touch
    /// costs nothing. Honors the file's EXIF orientation. nil if analysis fails.
    func liveTextAnalysis(for url: URL) async -> ImageAnalysis? {
        if let cached = analysisCache.value(url.path) { return cached }
        let orientation = ImageOCR.orientation(ofImageAt: url)
        let configuration = ImageAnalyzer.Configuration([.text])
        guard let analysis = try? await Self.analyzer.analyze(imageAt: url, orientation: orientation, configuration: configuration)
        else { return nil }
        analysisCache.set(url.path, analysis)
        return analysis
    }

    // MARK: - Backfill / single-image indexing

    /// Background backfill: OCR every image attachment not already cached, prune
    /// entries for attachments that no longer exist, then publish the name→text
    /// map search reads. A warm cache costs only a hash per image. Skipped
    /// entirely when the Attachments folder is unchanged since the last backfill.
    func refresh(store: NoteStore) {
        guard isEnabled else { clearForDisabled(); return }
        guard !refreshing else { return }
        let attachmentsDir = store.attachmentsDirectory
        let mtime = (try? attachmentsDir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let mtime, lastBackfillMTime[attachmentsDir.path] == mtime { return }
        refreshing = true
        let urls = store.imageAttachments()
        queue.async { [weak self] in
            guard let self else { return }
            var cache = self.cacheOnQueue()
            var names: [String: String] = [:]
            var presentHashes = Set<String>()
            var changed = false
            for url in urls {
                guard let hash = ImageOCR.contentHash(of: url) else { continue }
                presentHashes.insert(hash)
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
            // Drop entries for attachments that are gone, so the cache tracks the
            // vault instead of growing forever.
            let pruned = cache.filter { presentHashes.contains($0.key) }
            if pruned.count != cache.count { cache = pruned; changed = true }
            if changed { self.persistOnQueue(cache) } else { self.diskCache = cache }
            Task { @MainActor in
                self.searchText = names
                if let mtime { self.lastBackfillMTime[attachmentsDir.path] = mtime }
                self.refreshing = false
            }
        }
    }

    /// OCR a single freshly-added image (a capture, paste, or drop) and merge it
    /// into the search map — no full rescan, so inserting a picture stays cheap
    /// even in a large vault.
    func index(imageNamed name: String, store: NoteStore) {
        guard isEnabled,
              Note.imageAttachmentExtensions.contains((name as NSString).pathExtension.lowercased()) else { return }
        let url = store.attachmentURL(forName: name)
        queue.async { [weak self] in
            guard let self, let hash = ImageOCR.contentHash(of: url) else { return }
            var cache = self.cacheOnQueue()
            let text: String
            if let hit = cache[hash] {
                text = hit
            } else {
                text = ImageOCR.recognizeText(in: url) ?? ""
                cache[hash] = text
                self.persistOnQueue(cache)
            }
            guard !text.isEmpty else { return }
            Task { @MainActor in self.searchText[name.lowercased()] = text.lowercased() }
        }
    }

    /// Recognizes the text of one image off the main thread, reading (and
    /// filling) the shared cache, then delivers it on the main actor. Used by
    /// "Copy Text from Image" — the user waits only the first time per image.
    func recognizedText(for url: URL, completion: @escaping @MainActor (String) -> Void) {
        queue.async { [weak self] in
            let text: String
            if let self, let hash = ImageOCR.contentHash(of: url) {
                var cache = self.cacheOnQueue()
                if let hit = cache[hash] {
                    text = hit
                } else {
                    text = ImageOCR.recognizeText(in: url) ?? ""
                    cache[hash] = text
                    self.persistOnQueue(cache)
                }
            } else {
                text = ImageOCR.recognizeText(in: url) ?? ""
            }
            Task { @MainActor in completion(text) }
        }
    }

    /// Reacts to the OCR setting being toggled off at rest (the Settings toggle
    /// calls this): clear the search map now, and forget the backfill markers so
    /// re-enabling triggers a fresh rebuild on the next load.
    func applyEnabledSetting() {
        if !isEnabled { clearForDisabled() }
    }

    private func clearForDisabled() {
        searchText = [:]
        lastBackfillMTime.removeAll()
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
