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
