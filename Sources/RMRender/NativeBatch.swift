// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation

/// The native drawings of a run of overlay pages, drawn as the pages of one
/// PDF rather than as a PDF each.
///
/// CoreGraphics embeds a typeface once a document, cut down to the letters
/// that document sets. A PDF of its own for every page — what an overlay's
/// native Form was — cut every face afresh for every page, to that page's
/// letters, and no two cuts were alike: a test book of two hundred pages of
/// typed text carried 559 font programs, each different from the rest, and
/// the shared resources of the update (`PDFOverlayWriter.fingerprint`) had
/// nothing to merge. Drawn into one document, the pages of a run share one
/// cut of each face, and the update writes it once.
///
/// The ink after the last thing only CoreGraphics draws is written apart
/// (`InkStream`) and appended to the run's document, page by page, as it is
/// to a page drawn alone (`AnnotatedPDFRenderer.nativeMarks`).
///
/// One thing a document shares that a page drawn alone does not: CoreGraphics
/// keys an image on its bytes, and a grain mask drawn with the bytes of one
/// drawn earlier in the document takes the earlier one's dimensions
/// (`InkMaskLedger`). On a page of its own that mask had its own. A page on
/// which sharing the document would change a mask — known once it is drawn,
/// from the ledger the drawing went through — is refused (`page` answers
/// `nil`), and the caller draws it alone, as it always was drawn; its page
/// in the run's document is left for nobody to read.
///
/// Written to a file of its own, not to memory: a run's pictures are in it,
/// and a file read back mapped (`PDFFile(url:)`) is the system's to page out
/// rather than the process's to hold. The file belongs to the batch until
/// `finish` hands it on, and is removed if the batch is let go first.
///
/// Not `Sendable`: one task draws one run.
final class NativeBatch {
    private struct Drawing {
        let url: URL
        let sink: PDFSink
        let context: CGContext
        let update: InkUpdate
    }

    private var drawing: Drawing?
    /// How many pages the document has, refused ones included.
    private var count = 0

    deinit {
        if let drawing { try? FileManager.default.removeItem(at: drawing.url) }
    }

    /// A page of `mediaBox` drawn by `draw` — from a fresh graphics state,
    /// in the coordinates a PDF of that box alone would give it — with `ink`
    /// appended after it; the page's number in the run's document, counting
    /// from nought, or `nil` where the page has to be drawn alone (see above).
    ///
    /// `draw` is handed the ledger of the run's masks, to draw through as a
    /// page drawn alone draws through its own.
    func page(
        mediaBox: CGRect,
        ink: PreparedInk?,
        draw: (CGContext, InkMaskLedger) -> Void
    ) throws -> Int? {
        let drawing = try opened(mediaBox)
        let masks = drawing.update.masks
        let resized = masks.resized
        drawing.context.beginPDFPage(Self.pageInfo(mediaBox: mediaBox))
        draw(drawing.context, masks)
        drawing.context.endPDFPage()
        let number = count
        count += 1
        guard masks.resized == resized, !(ink.map { masks.wouldResize($0.masks) } ?? false) else { return nil }
        if let ink { try drawing.update.append(ink, page: number) }
        return number
    }

    /// The run's document finished — its ink appended — and handed on as
    /// the file it is in, which is the caller's from here; `nil` for a run
    /// that drew no page.
    func finish() throws -> URL? {
        guard let drawing else { return nil }
        self.drawing = nil
        do {
            drawing.context.closePDF()
            try drawing.update.finish(into: drawing.sink)
            try drawing.sink.close()
        } catch {
            try? FileManager.default.removeItem(at: drawing.url)
            throw error
        }
        return drawing.url
    }

    /// The document, begun at its first page.
    private func opened(_ mediaBox: CGRect) throws -> Drawing {
        if let drawing { return drawing }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(".rmrender-native-\(UUID().uuidString).pdf")
        let sink = try PDFSink(url: url)
        // A default only: every page states its own box.
        var box = mediaBox
        guard let consumer = sink.consumer(), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            try? sink.close()
            try? FileManager.default.removeItem(at: url)
            throw RenderError.pdfContextUnavailable
        }
        let drawing = Drawing(url: url, sink: sink, context: context, update: InkUpdate())
        self.drawing = drawing
        return drawing
    }

    /// A page's box as CoreGraphics takes it: the bytes of a `CGRect`.
    private static func pageInfo(mediaBox: CGRect) -> CFDictionary {
        var box = mediaBox
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        return [kCGPDFContextMediaBox as String: data] as CFDictionary
    }
}
