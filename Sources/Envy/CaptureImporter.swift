import AppKit
import PDFKit
import Vision
import CoreImage
import UniformTypeIdentifiers
import EnvyCore

/// The raw bytes of a capture, read off the pasteboard synchronously (on the
/// main thread, while the board is still valid) so the expensive processing can
/// then run on a background task. Sendable, so it crosses the actor hop.
enum CapturePayload: Sendable {
    case pdf(Data)   // Scan Documents → multi-page PDF
    case png(Data)   // Take Photo (or a screenshot) → image data
    case tiff(Data)
    case file(URL)   // a capture delivered only as a file URL
}

/// Turns a Continuity Camera capture into saved attachment files, shared by the
/// note editor's `readSelection` and the capture pill. A photo becomes one PNG;
/// a document scan (multi-page PDF) rasterizes to one cropped PNG per page. The
/// heavy work — rasterization, the Vision page-edge crop, PNG encoding — runs on
/// a background task so a multi-page scan never stalls the UI; only the final
/// attachment writes happen on the main actor. On-device, no network.
@MainActor
enum CaptureImporter {

    /// Image UTIs NSImage can read, plus PDF — a "Scan Documents" capture arrives
    /// as a multi-page PDF rather than an image. What a view vouches for as a
    /// Continuity Camera return type.
    static let acceptedTypes: Set<String> = {
        var types = Set(NSImage.imageTypes)
        types.insert(UTType.pdf.identifier)
        return types
    }()

    /// Reads a capture pasteboard synchronously into a Sendable payload (the
    /// board isn't safe to touch after the services callback returns), or nil if
    /// it carries nothing we handle.
    static func payload(from pboard: NSPasteboard) -> CapturePayload? {
        if let pdf = pboard.data(forType: NSPasteboard.PasteboardType(UTType.pdf.identifier)) { return .pdf(pdf) }
        if let png = pboard.data(forType: .png) { return .png(png) }
        if let tiff = pboard.data(forType: .tiff) { return .tiff(tiff) }
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first(where: { MarkdownStyler.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return .file(file)
        }
        return nil
    }

    /// Processes a payload — the heavy rasterize/crop/encode off the main thread —
    /// then writes the results into the store's Attachments on the main actor,
    /// returning the saved filenames in order.
    static func saveImages(_ payload: CapturePayload, into store: NoteStore) async -> [String] {
        let stamp = captureStamp()
        switch payload {
        case .pdf(let data):
            let pages = await Task.detached { rasterizedPages(fromPDF: data, stamp: stamp) }.value
            return pages.compactMap { store.saveAttachment(data: $0.data, base: $0.base, ext: "png") }
        case .png(let data):
            return [store.saveAttachment(data: data, base: "Photo - \(stamp)", ext: "png")].compactMap { $0 }
        case .tiff(let data):
            let png = await Task.detached { NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) }.value
            guard let png, let name = store.saveAttachment(data: png, base: "Photo - \(stamp)", ext: "png") else { return [] }
            return [name]
        case .file(let url):
            return [store.copyAttachment(from: url)].compactMap { $0 }
        }
    }

    /// Pulls PNG (or TIFF, re-encoded to PNG) image data off a pasteboard and
    /// stores it under `base`, returning the saved filename. Used by paste and
    /// drop (both light and already on the main thread); captures go through
    /// `payload`/`saveImages` instead.
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

    // MARK: - Background page processing (nonisolated: runs off the main thread)

    /// Rasterizes each page of a scanned PDF to PNG data, returning them in page
    /// order with their filename base. Rendered at 2× the page's point size so
    /// text stays crisp (and legible to OCR); a white backdrop stands in for
    /// paper behind any transparency. Runs off the main thread — no store access.
    nonisolated private static func rasterizedPages(fromPDF data: Data, stamp: String) -> [(base: String, data: Data)] {
        guard let doc = PDFDocument(data: data) else { return [] }
        let scale: CGFloat = 2
        var pages: [(base: String, data: Data)] = []
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
            pages.append((base, png))
        }
        return pages
    }

    /// Shared Core Image context for the crop pass (CIContext is thread-safe) —
    /// creating one per page spins up a fresh GPU pipeline each time.
    nonisolated private static let ciContext = CIContext()

    nonisolated private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Finds the page inside an already-flat scan and crops + deskews to its four
    /// corners, dropping the background margin the scanner left behind. Returns
    /// nil — caller keeps the original — when detection is unconfident or the
    /// page doesn't fill a real share of the frame (a guard against a spurious
    /// tiny quad over-cropping a good scan). On-device (Vision). Identity when
    /// the page already fills the frame, so it's safe to run unconditionally.
    nonisolated private static func documentCropped(_ image: CGImage) -> CGImage? {
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
