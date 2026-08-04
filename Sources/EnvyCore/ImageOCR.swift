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

    /// Recognizes text in an image file, or nil if it can't be decoded.
    public static func recognizeText(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return recognizeText(in: image)
    }

    /// Recognizes text in a decoded image using Vision in accurate mode with
    /// language correction, returning the recognized lines joined by newlines
    /// ("" when the image holds no legible text). Printed and whiteboard text
    /// comes back near-perfect; cursive is a coin flip — good enough that
    /// search still wins at partial accuracy.
    public static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
