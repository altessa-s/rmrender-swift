// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation

/// What a render does with a page whose bytes would not arrive — `PageBlobs`
/// failing with anything but a cancellation.
///
/// Such a page is not a property of the document: it is the network, or the
/// cache, and the next try may bring it. A page whose bytes arrived and do
/// not parse is the document's own, and is drawn the way it always was
/// (`onUnreadable`) whatever this says.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum UnfetchedPagePolicy: Sendable, Hashable {
    /// The page is drawn with "Rendering error" in the middle of it, so it
    /// cannot be taken for a page nobody wrote on: a plain white sheet of
    /// the page's size in a notebook, the original page under the label in
    /// an annotated document. The rest of the document is drawn, and
    /// `onUnfetched` is told.
    case placeholder
    /// The page is drawn as one that does not parse: a blank sheet on its
    /// template in a notebook, the original page without its marks in an
    /// annotated document. The rest of the document is drawn, and
    /// `onUnfetched` is told.
    case blank
    /// The render fails with `PageFetchError`, naming the page, and writes
    /// no output.
    case strict
}

/// A render refused under `UnfetchedPagePolicy.strict`: the bytes of a page
/// would not arrive.
///
/// A type of its own rather than a case of `RenderError`: that enum is frozen
/// and switched over exhaustively by those who link it, and a case added to
/// it would break their builds.
public struct PageFetchError: Error, CustomStringConvertible {
    /// The page's place in the rendered document, counting from zero — the
    /// numbering of `ParsedNotebook.unfetched` and of the output's pages.
    public let page: Int
    /// The document's own name for the page: its `.rm` file, without the
    /// extension.
    public let pageID: String
    /// What `PageBlobs` failed with.
    public let underlying: any Error

    public init(page: Int, pageID: String, underlying: any Error) {
        self.page = page
        self.pageID = pageID
        self.underlying = underlying
    }

    public var description: String {
        "the bytes of page \(page) (\(pageID)) did not arrive: \(String(describing: underlying))"
    }
}

/// The label an unfetched page is drawn with under
/// `UnfetchedPagePolicy.placeholder`, in one place for every route — a
/// notebook's PDF and bitmaps, an annotated document overlaid or redrawn.
enum UnfetchedPlaceholder {
    static let label = "Rendering error"

    /// The label's size against the width of the sheet it stands on, so it
    /// reads the same on a phone-sized page and a poster.
    static let sizeOfWidth = 0.05

    /// The label centred on `sheet`, in the context's own coordinates —
    /// points on a PDF page, pixels on a bitmap — upright with y upwards:
    /// dark grey text on a light rounded box, set in the face typed text is
    /// set in (`EmbeddedFonts.body`), so it embeds the way typed text does.
    static func draw(on sheet: CGRect, in context: CGContext) {
        guard sheet.width > 0, sheet.height > 0 else { return }
        let size = sheet.width * sizeOfWidth
        let text = CGColor(gray: 0.25, alpha: 1)
        let string = CFAttributedStringCreate(
            nil,
            label as CFString,
            [
                kCTFontAttributeName: EmbeddedFonts.body(size: size),
                kCTForegroundColorAttributeName: text,
            ] as CFDictionary
        )
        guard let string else { return }
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let height = ascent + descent
        let box = CGRect(
            x: sheet.midX - width / 2 - size * 0.8,
            y: sheet.midY - height / 2 - size * 0.5,
            width: width + size * 1.6,
            height: height + size
        )

        context.saveGState()
        let corner = size * 0.35
        let outline = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.addPath(outline)
        context.setFillColor(gray: 0.95, alpha: 1)
        context.fillPath()
        context.addPath(outline)
        context.setStrokeColor(gray: 0.7, alpha: 1)
        context.setLineWidth(max(size * 0.06, 0.5))
        context.strokePath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: sheet.midX - width / 2, y: sheet.midY - height / 2 + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The label as a one-page PDF of `mediaBox`, centred on `drawingBox` —
    /// what the overlay imports as a page's native Form, the way it imports
    /// typed text (`AnnotatedPDFRenderer.nativeMarks`).
    static func form(drawingBox: CGRect, mediaBox: CGRect) throws -> Data {
        guard let data = CFDataCreateMutable(nil, 0) else { throw RenderError.pdfContextUnavailable }
        var media = mediaBox
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenderError.pdfContextUnavailable
        }
        context.beginPDFPage(nil)
        draw(on: drawingBox, in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
