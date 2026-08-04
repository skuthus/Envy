import Foundation
import Vision
import ImageIO
import CryptoKit

/// On-device text recognition for image attachments — the engine behind
/// "Copy Text from Image", searchable scans, and Live Text. Pure and
/// synchronous (call it off the main thread); Vision does the work locally,
/// no network. Keyed for caching by the image's content hash, so recognition
/// survives a rename and two identical images share one result.
public enum ImageOCR {

    /// SHA-256 (hex) of a file's bytes — the OCR cache key. Content-addressed,
    /// so renaming an attachment doesn't re-OCR it and a synced copy on another
    /// Mac reuses the same entry. nil when the file can't be read.
    public static func contentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The image file's stored EXIF orientation (`.up` when none / unreadable).
    /// Recognition works on the raw pixel buffer, which ignores EXIF, so this
    /// must be handed to Vision — otherwise a rotated photo (common from a phone
    /// or Photos) is recognized sideways while it displays upright, and every
    /// box/selection lands rotated.
    public static func orientation(ofImageAt url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }

    /// Recognizes text in an image file, or nil if it can't be decoded.
    public static func recognizeText(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return recognizeText(in: image, orientation: orientation(ofImageAt: url))
    }

    /// Recognizes text in a decoded image using Vision in accurate mode with
    /// language correction, returning the recognized lines joined by newlines
    /// ("" when the image holds no legible text). Printed and whiteboard text
    /// comes back near-perfect; cursive is a coin flip — good enough that
    /// search still wins at partial accuracy.
    public static func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation = .up) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// One recognized word and where it sits — its `box` normalized in Vision's
    /// space (origin bottom-left, 0…1), so it maps onto the displayed image
    /// regardless of scale. Word-level, not character-level: Vision's
    /// `boundingBox(for:)` returns the whole-word box for any sub-range (verified
    /// even on printed text), so a search match lights the whole word. Sendable,
    /// so it crosses back from the recognition task cleanly (unlike a VNObservation).
    public struct OCRWord: Sendable {
        public let text: String   // lowercased
        public let box: CGRect    // normalized, bottom-left origin
    }

    /// Recognizes every word in an image file with its bounding box — the basis
    /// for highlighting search matches on the picture. Returns [] if the file
    /// can't be read. Synchronous; call it off the main thread.
    public static func recognizeWords(in url: URL) -> [OCRWord] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return recognizeWords(in: image, orientation: orientation(ofImageAt: url))
    }

    public static func recognizeWords(in image: CGImage, orientation: CGImagePropertyOrientation = .up) -> [OCRWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }
        var words: [OCRWord] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { sub, range, _, _ in
                guard let sub, !sub.isEmpty,
                      let boxed = try? candidate.boundingBox(for: range) else { return }
                words.append(OCRWord(text: sub.lowercased(), box: boxed.boundingBox))
            }
        }
        return words
    }
}
