import AppKit
import PDFKit
import Vision
import CoreImage
import UniformTypeIdentifiers
import EnvyCore

/// Turns a Continuity Camera capture (or a pasted/dropped image) into saved
/// attachment files, shared by the note editor's `readSelection` and the
/// capture pill beside the search field. A photo becomes one PNG; a document
/// scan (multi-page PDF) rasterizes to one cropped PNG per page. On-device: the
/// page-edge crop is Vision + Core Image, no network.
///
/// Main-actor isolated: it touches the store's attachment writers and runs from
/// the capture handlers (readSelection), which are already on the main thread —
/// same as when this logic lived in the text view.
@MainActor
enum CaptureImporter {

    /// Image UTIs NSImage can read, plus PDF — a "Scan Documents" capture
    /// arrives as a multi-page PDF rather than an image. What a view vouches for
    /// as a Continuity Camera return type.
    static let acceptedTypes: Set<String> = {
        var types = Set(NSImage.imageTypes)
        types.insert(UTType.pdf.identifier)
        return types
    }()

    /// Saves everything on a capture pasteboard into the store's Attachments,
    /// returning the saved filenames in order — one per scanned page, or one for
    /// a photo. Empty when the board carries nothing we can use.
    static func saveImages(from pboard: NSPasteboard, into store: NoteStore) -> [String] {
        let stamp = captureStamp()

        // Scan Documents → PDF: rasterize every page, no PDF attachment.
        if let pdf = pboard.data(forType: NSPasteboard.PasteboardType(UTType.pdf.identifier)) {
            return rasterizedPageNames(fromPDF: pdf, store: store, stamp: stamp)
        }
        // Take Photo → image data.
        if let name = imageName(from: pboard, store: store, base: "Photo - \(stamp)") {
            return [name]
        }
        // A capture delivered only as a file URL on the board.
        if let urls = pboard.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first(where: { MarkdownStyler.imageExtensions.contains($0.pathExtension.lowercased()) }),
           let name = store.copyAttachment(from: file) {
            return [name]
        }
        return []
    }

    /// Pulls PNG (or TIFF, re-encoded to PNG) image data off a pasteboard and
    /// stores it under `base`, returning the saved filename. Paste and drop keep
    /// the default "Pasted image"; a captured photo passes "Photo - <stamp>".
    static func imageName(from pb: NSPasteboard, store: NoteStore, base: String = "Pasted image") -> String? {
        if let data = pb.data(forType: .png) {
            return store.saveAttachment(data: data, base: base, ext: "png")
        }
        if let tiff = pb.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return store.saveAttachment(data: png, base: base, ext: "png")
        }
        return nil
    }

    /// The `YYMMDD-HHmmss` stamp that dates a capture's filename — sortable
    /// (unlike MMDDYY) and filesystem-safe. POSIX locale so it never localizes.
    static func captureStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Rasterizes each page of a scanned PDF to a PNG in the vault, returning the
    /// saved filenames in page order. Rendered at 2× the page's point size so
    /// text stays crisp on screen (and legible to OCR); a white backdrop stands
    /// in for paper behind any transparency. Rasterize rather than attach the
    /// PDF, so scans ride the same image pipeline as every other embed.
    private static func rasterizedPageNames(fromPDF data: Data, store: NoteStore, stamp: String) -> [String] {
        guard let doc = PDFDocument(data: data) else { return [] }
        let scale: CGFloat = 2
        var names: [String] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pw = Int(bounds.width * scale), ph = Int(bounds.height * scale)
            guard pw > 0, ph > 0,
                  let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            cg.setFillColor(NSColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
            cg.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: cg)   // handles the page's box + rotation
            NSGraphicsContext.restoreGraphicsState()
            guard var pageImage = rep.cgImage else { continue }
            if let cropped = documentCropped(pageImage) { pageImage = cropped }
            guard let png = pngData(from: pageImage) else { continue }
            // "Scan - 260803-214234", the pages of one scan sharing a stamp and
            // numbered "- p2", "- p3"; a single-page scan drops the page suffix.
            let base = doc.pageCount > 1 ? "Scan - \(stamp) - p\(index + 1)" : "Scan - \(stamp)"
            if let name = store.saveAttachment(data: png, base: base, ext: "png") {
                names.append(name)
            }
        }
        return names
    }

    /// Shared Core Image context for the crop pass — creating one per page spins
    /// up a fresh GPU pipeline each time.
    private static let ciContext = CIContext()

    private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Finds the page inside an already-flat scan and crops + deskews to its four
    /// corners, dropping the background margin the scanner left behind. Returns
    /// nil — caller keeps the original — when detection is unconfident or the
    /// page doesn't fill a real share of the frame (a guard against a spurious
    /// tiny quad over-cropping a good scan). On-device (Vision). Identity when
    /// the page already fills the frame, so it's safe to run unconditionally.
    private static func documentCropped(_ image: CGImage) -> CGImage? {
        // Opt-out (Settings → Editor → "Crop scans to the page edge"); default on.
        guard UserDefaults.standard.object(forKey: "scanAutoCrop") as? Bool ?? true else { return nil }
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let page = request.results?.first,
              page.confidence > 0.5 else { return nil }
        let box = page.boundingBox
        guard box.width * box.height > 0.4 else { return nil }

        // Vision's normalized corners share CIImage's bottom-left origin, so
        // scaling by pixel size maps straight across with no flip.
        let source = CIImage(cgImage: image)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func corner(_ point: CGPoint) -> CIVector { CIVector(x: point.x * w, y: point.y * h) }
        let corrected = source.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": corner(page.topLeft),
            "inputTopRight": corner(page.topRight),
            "inputBottomLeft": corner(page.bottomLeft),
            "inputBottomRight": corner(page.bottomRight),
        ])
        return ciContext.createCGImage(corrected, from: corrected.extent)
    }
}
