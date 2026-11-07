// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation
import RMMarks
import RMLines

/// Drawing parsed pages into a PDF.
///
/// Free functions with no actor isolation: a caller can run them from
/// `Task.detached`, so that rendering a large notebook does not occupy any
/// of its actors.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum PageRenderer {
    /// The tablet's page size in points, one to one with its pixels. A
    /// document may declare its own (`customZoomPageWidth` and
    /// `customZoomPageHeight` in `.content`) — this value is for when it says
    /// nothing.
    public static let defaultPageSize = CGSize(width: 1404, height: 1872)

    /// The longest side a declared canvas may have, in `.rm` units.
    ///
    /// Not a measurement but a fence: every tablet's canvas is a couple of
    /// thousand units a side, and a declared size is read off a file —
    /// `customZoomPageWidth` in `.content`, the scene block of a page — that
    /// can say `1e300`. Taken at its word that is a bitmap nobody can
    /// allocate, a PDF box no reader opens, and an `Int(_:)` that traps.
    static let maximumCanvasSide: CGFloat = 100_000

    /// A declared canvas, or `nil` where it is not one a page could have:
    /// not finite, not positive, or past `maximumCanvasSide`. A size refused
    /// here is a size not declared, and the next one in line has its say.
    static func plausibleCanvas(_ size: CGSize?) -> CGSize? {
        guard let size,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= maximumCanvasSide, size.height <= maximumCanvasSide
        else { return nil }
        return size
    }

    /// The most pixels one page's bitmap may have — a gigabyte in RGBA. Four
    /// times the pixel ceiling of an attachment, and the same kind of
    /// number: a Paper Pro page grown five sheets down and drawn at twice its
    /// size is about seventy megapixels, while ink written a million units
    /// below the page asks for billions, which is the process killed for
    /// memory rather than an error. Past it the page is refused with
    /// `RenderError.bitmapContextUnavailable`, as CoreGraphics would refuse
    /// a context it cannot make.
    static let maximumPagePixels = 256_000_000

    /// The renderer version: a number that changes whenever the same input
    /// would be drawn differently. A host that caches rendered pages can key
    /// its cache on it, so that output made under old drawing rules is
    /// replaced.
    ///
    /// Bump it together with any change to the drawing or to the numbers in
    /// `Calibration`. Never reuse a number.
    public static let version = 95

    /// The pages as a PDF held in memory.
    ///
    /// Convenient, and that is all it is for: the whole output stands in the
    /// process beside the parsed pages and their attachments. The product path
    /// writes to a file — see the overload below. This one is for tests and for
    /// command-line use, where the documents are small and a `Data` reads better.
    ///
    /// An image whose attachment is absent from `assets`, or whose bytes do
    /// not decode, leaves a hole where it stood and a line in the log; the
    /// page is drawn all the same. The same holds for the other entry points
    /// here.
    public static func pdf(
        pages: [RMPage],
        pageSize: CGSize = defaultPageSize,
        paper: PaperSize = .a4,
        // The bytes of the pages' attachments, by file name. They live in
        // the document's index as blobs of their own, so the caller fetches
        // and the renderer draws.
        assets: [String: Data] = [:],
        author: String? = nil
    ) throws -> Data {
        guard let buffer = CFDataCreateMutable(nil, 0) else {
            throw RenderError.pdfContextUnavailable
        }
        try pdf(
            pages: pages, pageSize: pageSize, paper: paper, assets: assets, author: author,
            into: PDFSink(data: buffer)
        )
        return buffer as Data
    }

    /// One page as a bitmap, for OCR and anything else that needs pixels
    /// rather than a PDF.
    ///
    /// The same stroke and template drawing as the PDF path, without a PDF
    /// intermediary: Vision asks for a `CGImage`, and round-tripping through
    /// a page of a PDF would spend memory and lose nothing worth keeping.
    /// `scale` multiplies the tablet canvas — 1 is one pixel per point.
    /// `inkOnly` draws the handwriting alone — no typed text, no highlight,
    /// no placed picture — for a recogniser that is to read the hand and
    /// nothing else: typed text is carried as text by whoever asks, and a
    /// page with both would give it twice. The text is still laid out, so
    /// the strokes anchored to it keep their places.
    public static func image(
        page: RMPage,
        pageSize: CGSize = defaultPageSize,
        scale: CGFloat = 1,
        assets: [String: Data] = [:],
        inkOnly: Bool = false,
        grayscale: Bool = false
    ) throws -> CGImage {
        try image(
            page: page, pageSize: pageSize, scale: scale, images: PageImages(bytes: assets), inkOnly: inkOnly,
            grayscale: grayscale
        )
    }

    /// The same, with the attachments already decoded where a caller has
    /// them so (`ParsedNotebook.images`).
    static func image(
        page: RMPage,
        pageSize: CGSize,
        scale: CGFloat,
        images: PageImages,
        inkOnly: Bool,
        grayscale: Bool
    ) throws -> CGImage {
        // Grown as a PDF page grows (`grownSheet`, shared with
        // `pdf(pages:pageSize:paper:...)` above), but never cut: a page
        // stretched with the tablet's "extend page" runs its ink past
        // `pageSize` on purpose, and a bitmap allocated at the plain
        // `pageSize` simply never has the pixels for what lies beyond it —
        // not blurred, not downscaled, absent, which is why no OCR engine
        // could ever have recognised it. An exported PDF trims ink that
        // hangs a little over an edge, and the PDF path follows it; a
        // bitmap is read by an engine or looked at as a picture, and a line
        // written just under the edge is a line lost to both.
        let geometry = page.text.map { TextGeometry($0, pageSize: pageSize) }
        let bounds = contentBounds(of: page, pageSize: pageSize, edge: .uncut, geometry: geometry)
        let sheet = grownSheet(from: bounds, floor: pageSize, scale: 1)
        let context = try whiteBitmap(sheet: sheet, scale: scale, grayscale: grayscale)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        // The same placement the PDF page uses to put a grown page's ink on
        // its sheet: centred sideways, pressed to the top. `scale: 1` here —
        // the device-pixel density already went into `context.scaleBy`
        // above, and this transform only has to place `.rm` units on a sheet
        // stated in the same units.
        context.concatenate(placement(of: bounds, on: sheet, scale: 1))
        draw(
            page, in: context, pageSize: pageSize, bounds: bounds, images: images, inkOnly: inkOnly, geometry: geometry
        )
        context.restoreGState()
        guard let image = context.makeImage() else {
            throw RenderError.bitmapContextUnavailable
        }
        return image
    }

    /// The bitmap of a page whose bytes did not arrive, under
    /// `UnfetchedPagePolicy.placeholder`: a white sheet of the size a page
    /// with nothing on it is drawn at, "Rendering error" in the middle.
    static func placeholderImage(pageSize: CGSize, scale: CGFloat, grayscale: Bool) throws -> CGImage {
        let blank = RMPage(strokes: [], skippedBlocks: 0)
        let bounds = contentBounds(of: blank, pageSize: pageSize, edge: .uncut, geometry: nil)
        let sheet = grownSheet(from: bounds, floor: pageSize, scale: 1)
        let context = try whiteBitmap(sheet: sheet, scale: scale, grayscale: grayscale)
        UnfetchedPlaceholder.draw(on: CGRect(x: 0, y: 0, width: context.width, height: context.height), in: context)
        guard let image = context.makeImage() else {
            throw RenderError.bitmapContextUnavailable
        }
        return image
    }

    /// A white bitmap for a sheet of `sheet` units at `scale` pixels a unit.
    private static func whiteBitmap(sheet: CGSize, scale: CGFloat, grayscale: Bool) throws -> CGContext {
        // Weighed as floating point before a single `Int(_:)`: the sheet
        // follows the ink, the ink is the file's, and a stroke at y = 1e30
        // makes a height no `Int` holds — a trap, not a failure. A `scale`
        // that is not a number is refused the same way.
        let wide = (sheet.width * scale).rounded(), high = (sheet.height * scale).rounded()
        let ceiling = CGFloat(maximumPagePixels)
        guard wide.isFinite, high.isFinite, abs(wide) <= ceiling, abs(high) <= ceiling, wide * high <= ceiling else {
            RMRenderLog.pageError("render: a page of \(wide)×\(high) pixels is past what is drawn")
            throw RenderError.bitmapContextUnavailable
        }
        let width = max(1, Int(wide))
        let height = max(1, Int(high))
        // Grey at one byte a pixel where the caller reads ink and no colour:
        // a page of a Paper Pro is 31 MB in RGBA and 8 in grey, and a
        // recogniser holds a whole notebook of them at once.
        let bytesPerRow = width * (grayscale ? 1 : 4)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (grayscale ? CGImageAlphaInfo.none : CGImageAlphaInfo.premultipliedLast).rawValue
        ) else {
            throw RenderError.bitmapContextUnavailable
        }
        // White sheet: Vision is happier on ink over paper than on ink over
        // transparent black, and a notebook page is white on the tablet.
        if grayscale {
            context.setFillColor(gray: 1, alpha: 1)
        } else {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// The pages as a PDF written straight to `url`.
    ///
    /// A host may run the drawing under a tight memory limit, and a big
    /// notebook holds its parsed pages and its attachments while it draws.
    /// Handing the output back as `Data` for the caller to write adds the
    /// whole document to that on top — the same reason `AnnotatedPDFRenderer`
    /// consumes a URL. Anything already at `url` is replaced.
    public static func pdf(
        pages: [RMPage],
        pageSize: CGSize = defaultPageSize,
        paper: PaperSize = .a4,
        assets: [String: Data] = [:],
        author: String? = nil,
        to url: URL
    ) throws {
        do {
            try pdf(pages: pages, pageSize: pageSize, paper: paper, assets: assets, author: author, into: PDFSink(url: url))
        } catch {
            // A cancelled or failed render leaves a truncated PDF behind, and
            // a truncated PDF at the path the caller asked for is worse than
            // nothing: it opens, and it is wrong.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func pdf(
        pages: [RMPage],
        pageSize: CGSize,
        paper: PaperSize,
        assets: [String: Data],
        author: String?,
        into sink: PDFSink
    ) throws {
        let output = try PDFPages(sink: sink, pageSize: pageSize, paper: paper, author: author)
        let images = PageImages(bytes: assets)
        // An empty notebook must still produce a file that opens.
        for page in pages.isEmpty ? [RMPage(strokes: [], skippedBlocks: 0)] : pages {
            // A caller may cancel a render it does not need, and drawing is
            // the long part of it. Asked here
            // rather than inside a page: a page is a bounded piece of work,
            // and stopping between two of them costs nothing to reason about.
            try Task.checkCancellation()
            try output.draw(page, images: images)
        }
        try output.close()
    }

    /// A notebook's PDF written a page at a time.
    ///
    /// Apart from the loop above so that a caller can hand the pages over as
    /// it comes to them: `NotebookRenderer` parses a page when it is drawn and
    /// lets it go once it has been, and a list of every page parsed — what
    /// the loop above takes — is the memory that keeps a long notebook from
    /// being exported at all. Not `Sendable`: it is a `CGContext`, and it is
    /// used from the one task that made it.
    ///
    /// A page is drawn in two halves. Its ink — the strokes after the last
    /// thing only CoreGraphics draws (`inkSplit(of:images:)`) — is written
    /// apart by `Sheets.prepare`, which touches nothing shared and so runs
    /// on as many pages at once as the caller likes; CoreGraphics draws the
    /// rest, the template and the typed text and the pictures, here, a page
    /// at a time. The ink is appended after CoreGraphics' drawing of the
    /// page when the document is closed (`InkUpdate`), and the page paints
    /// what CoreGraphics drawing it all would have painted.
    final class PDFPages {
        /// What a page's sheet is worked out from: the same for every page
        /// of the document, and all a page's preparation needs.
        struct Sheets: Sendable {
            let pageSize: CGSize
            let paperSize: CGSize
            let scale: CGFloat

            /// `page` made ready to draw: its sheet measured and its ink
            /// written. Touches nothing but the page.
            func prepare(_ page: RMPage) -> Prepared {
                // The sheet is worked out per page. One sheet for the whole
                // notebook would mean that a single page written far down
                // squeezes all the others: on a three-page document the scale
                // would fall to 20%. Exported PDFs do the same — their pages
                // differ in height while the scale stays put.
                let geometry = page.text.map { TextGeometry($0, pageSize: pageSize) }
                let bounds = contentBounds(of: page, pageSize: pageSize, edge: .ribbon, geometry: geometry)
                let sheet = grownSheet(from: bounds, floor: paperSize, scale: scale)
                let placement = placement(of: bounds, on: sheet, scale: scale)
                let ink = writtenInk(of: page, pageSize: pageSize, geometry: geometry) { $0.concatenate(placement) }
                return Prepared(page: page, bounds: bounds, sheet: sheet, split: ink.split, ink: ink.ink)
            }
        }

        /// A page made ready to draw, by `Sheets.prepare`.
        struct Prepared: Sendable {
            let page: RMPage
            let bounds: CGRect
            let sheet: CGSize
            /// Where CoreGraphics' strokes end and the written ink begins.
            let split: Int
            let ink: PreparedInk?
        }

        private let context: CGContext
        private let sink: PDFSink
        private let update = InkUpdate()
        let sheets: Sheets
        private var drawn = 0

        init(sink: PDFSink, pageSize: CGSize, paper: PaperSize, author: String?) throws {
            // The page canvas decides the sheet only for the "as tablet" paper:
            // each tablet model declares its own canvas.
            let paperSize = paper.points(forCanvas: pageSize)
            var mediaBox = CGRect(origin: .zero, size: paperSize)
            let info = PDFDocumentInfo.dictionary(author: author)
            guard let consumer = sink.consumer(), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
                throw RenderError.pdfContextUnavailable
            }
            self.context = context
            self.sink = sink
            // The scale is set by the width and is one for the whole document:
            // the tablet's page fits exactly into the width of the chosen sheet.
            // That way nothing is squeezed — exactly as in exported PDFs, where
            // every page carries one and the same coefficient.
            sheets = Sheets(pageSize: pageSize, paperSize: paperSize, scale: paperSize.width / pageSize.width)
        }

        func draw(_ page: RMPage, images: PageImages) throws {
            try draw(sheets.prepare(page), images: images)
        }

        /// A prepared page drawn: CoreGraphics' half now, the ink when the
        /// document is closed.
        func draw(_ prepared: Prepared, images: PageImages) throws {
            let pageSize = sheets.pageSize
            let geometry = prepared.page.text.map { TextGeometry($0, pageSize: pageSize) }
            context.beginPDFPage(pageInfo(mediaBox: CGRect(origin: .zero, size: prepared.sheet)))
            context.saveGState()
            context.concatenate(placement(of: prepared.bounds, on: prepared.sheet, scale: sheets.scale))
            PageRenderer.draw(
                prepared.page, in: context, pageSize: pageSize, bounds: prepared.bounds, images: images,
                geometry: geometry, templateIsArtifact: true, inkSplit: prepared.split, masks: update.masks
            )
            context.restoreGState()
            context.endPDFPage()
            if let ink = prepared.ink { try update.append(ink, page: drawn) }
            drawn += 1
        }

        /// A page whose bytes did not arrive, under
        /// `UnfetchedPagePolicy.placeholder`: a plain sheet of the size a page
        /// with nothing on it is drawn at — no template, so that it cannot be
        /// taken for a page nobody wrote on — and "Rendering error" in the
        /// middle. It has no ink to append, and takes its number all the same.
        func drawPlaceholder() {
            let sheet = sheets.prepare(RMPage(strokes: [], skippedBlocks: 0)).sheet
            let box = CGRect(origin: .zero, size: sheet)
            context.beginPDFPage(pageInfo(mediaBox: box))
            UnfetchedPlaceholder.draw(on: box, in: context)
            context.endPDFPage()
            drawn += 1
        }

        /// The document finished: CoreGraphics' half closed, the ink
        /// appended.
        func close() throws {
            context.closePDF()
            try update.finish(into: sink)
            try sink.close()
        }
    }

    /// The ink of `page` written apart, and where it begins: the strokes
    /// from `inkSplit(of:images:)` on, written under the transform the page
    /// is drawn under — `place` applied to a fresh context, the way the
    /// drawing applies it to its own, so that the transform is CoreGraphics'
    /// to the bit. A page whose transform the writer does not take
    /// (`InkStream.init(transform:)`) is CoreGraphics' whole: its split is
    /// its count of strokes, and it has no ink.
    static func writtenInk(
        of page: RMPage, pageSize: CGSize, geometry: TextGeometry?, place: (CGContext) -> Void
    ) -> (split: Int, ink: PreparedInk?) {
        let placed = strokes(of: page, geometry: geometry)
        let split = inkSplit(of: placed, images: images(of: page, geometry: geometry))
        guard split < placed.count,
              let transform = contextTransform(place),
              let stream = InkStream(transform: transform)
        else { return (placed.count, nil) }
        writeInk(page, into: stream, pageSize: pageSize, geometry: geometry, from: split)
        // Ink that could not be deflated is CoreGraphics' again, all of it.
        guard let ink = PreparedInk(stream) else { return stream.isEmpty ? (split, nil) : (placed.count, nil) }
        return (split, ink)
    }

    /// The transform a context is left with by `apply`, from a fresh one's.
    /// A one-pixel bitmap does the arithmetic: a context's transform is
    /// worked the same whatever it draws into, and its own starts where a
    /// PDF page's does, at the identity.
    static func contextTransform(_ apply: (CGContext) -> Void) -> CGAffineTransform? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), context.ctm.isIdentity
        else { return nil }
        apply(context)
        return context.ctm
    }

    /// The sheet size for one PDF page.
    ///
    /// The context is created with a single `mediaBox` for the whole
    /// document, and it can be overridden only here, by the page's
    /// dictionary. The value goes as `CFData` holding the bytes of a
    /// `CGRect`, otherwise CoreGraphics silently ignores it.
    private static func pageInfo(mediaBox: CGRect) -> CFDictionary {
        var box = mediaBox
        let data = withUnsafeBytes(of: &box) { raw in
            CFDataCreate(nil, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        return [kCGPDFContextMediaBox as String: data as Any] as CFDictionary
    }

    /// The sheet a page's content needs: at least `floor`, grown to whatever
    /// `bounds` — `contentBounds`'s answer — comes back past it.
    ///
    /// Whole points, because that is what exports carry: every one of
    /// the 23 different boxes in a Move export of the corpus is a whole
    /// number, and each is its sheet in units times the unit, rounded —
    /// 1458.303 × 0.317181 = 462.545 comes back as 463, and 820.295 ×
    /// 0.317181 = 260.182 as 260. Rounded here rather than in `placement`:
    /// the box is what gets rounded, the content keeps the scale it was
    /// drawn at.
    /// Internal rather than private because `PageMarks` measures the same
    /// sheet: a band is answered in fractions of the bitmap this sizes, and
    /// a second copy of the sizing would put the bands a little beside the
    /// pixels they were taken from.
    static func grownSheet(from bounds: CGRect, floor: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(floor.width, bounds.width * scale).rounded(),
            height: max(floor.height, bounds.height * scale).rounded()
        )
    }

    /// The transform that places the content on the sheet without distorting
    /// the proportions. Reachable for the same reason as `grownSheet`: a mark
    /// is turned into fractions of the bitmap by reading this back.
    ///
    /// The scale comes from outside and does not depend on the content:
    /// horizontally the content is centred, vertically it is pressed to the
    /// top. The top rather than the centre, because the sheet grows downwards
    /// to fit what is written below the page edge, and the template has to
    /// begin where the page begins.
    static func placement(of bounds: CGRect, on sheet: CGSize, scale: CGFloat) -> CGAffineTransform {
        guard bounds.width > 0, bounds.height > 0 else { return .identity }
        let dx = (sheet.width - bounds.width * scale) / 2 - bounds.minX * scale
        let dy = sheet.height - bounds.maxY * scale
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    /// Draw a page's contents into a context already placed in `.rm` space.
    ///
    /// `inkSplit` stops the strokes there: the rest are written apart
    /// (`writeInk`) and appended after what is drawn here, which is the page
    /// up to them (`inkSplit(of:images:)`). `masks` is the document's record
    /// of the grain masks drawn so far, for a PDF whose ink is partly
    /// written apart — see `InkMaskLedger`.
    ///
    /// Internal rather than private because `AnnotatedPDFRenderer` puts the
    /// same strokes onto a page of an imported PDF. The alternative would be
    /// a second copy of the stroke drawing — the most intricate part of the
    /// renderer (the eraser, the order of point fields, the text anchors),
    /// and a copy would have to be corrected twice.
    static func draw(
        _ page: RMPage,
        in context: CGContext,
        pageSize: CGSize,
        bounds: CGRect,
        images pictures: PageImages = PageImages(),
        inkOnly: Bool = false,
        geometry laidOut: TextGeometry? = nil,
        templateIsArtifact: Bool = false,
        inkSplit: Int? = nil,
        masks: InkMaskLedger? = nil
    ) {
        // The template comes first: the handwriting is drawn over it, as on
        // the tablet. Unless the user hid it — the flag is the page's own
        // (`RMPage.backgroundVisible`), and drawing a hidden template shows
        // what was put away.
        if page.backgroundVisible,
           let name = page.templateName, let template = TemplateStore.shared.template(named: name) {
            // On a PDF page the ruling is marked as an artifact where the
            // system offers the mark: lines and dots are not content, and a
            // reader that reflows, extracts or searches the page leaves them
            // out. A bitmap has no such mark and is not offered one.
            let marked = templateIsArtifact && Self.markTemplateAsArtifact(in: context)
            // The canvas is turned by the document's own orientation field and
            // by nothing else (`NotebookRenderer.canvas`), so a page can end up
            // upright while carrying a template written for the long edge — a
            // document switched back to portrait keeps the templates its pages
            // were given. Such a template runs off the right-hand edge, and
            // this is the only place that can see it coming. Said out loud
            // rather than worked around: turning the canvas on the template's
            // say-so would contradict the document.
            if template.isLandscape, pageSize.height > pageSize.width {
                RMRenderLog.templateError(
                    """
                    landscape template \(name) on an upright \
                    \(pageSize.width)×\(pageSize.height) page — \
                    its right-hand side will be cut off
                    """
                )
            }
            // The template's dimensions are the page's dimensions: all its
            // insets are worked out from them. Yet it has to fill the whole
            // sheet, including what grew below the page edge, otherwise there
            // would be no lines under what is written there. Exported PDFs do
            // the same: the ruling runs to the very bottom of the grown
            // canvas.
            //
            // Fenced at `maximumCanvasSide`, though: the extent follows the
            // ink, the ink is the file's, and a stroke a billion units down
            // would have the ruling repeated ten thousand times each way —
            // a hundred million cells of a dot grid written into one page.
            TemplateRenderer.draw(
                template,
                in: context,
                size: pageSize,
                extent: CGSize(
                    width: min(max(pageSize.width, bounds.maxX), maximumCanvasSide),
                    height: min(pageSize.height - bounds.minY, maximumCanvasSide)
                )
            )
            #if RMRENDER_PDF_TAGGING
            if marked, #available(macOS 27, *) { context.endMarkedContentSequence() }
            #endif
        }

        // Where the typed text lands: worked out once, and read twice — the
        // text is drawn from it, and so is the handwriting anchored to that
        // text. A caller that measured the page for its sheet hands the
        // layout in, so a page is laid out once, not once per question.
        let geometry = laidOut ?? page.text.map { TextGeometry($0, pageSize: pageSize) }

        // Typed text goes under the handwriting, as on the tablet: notes are
        // written over the text, not beneath it.
        if let geometry, !inkOnly {
            draw(geometry, in: context, pageSize: pageSize)
        }

        // The marker goes under the handwriting and over the page, the way it
        // does on the tablet.
        //
        // Multiply, not transparency, and that matches exported PDFs rather
        // than being chosen: the text under a highlight keeps
        // its red and green and loses only blue — (55,55,55) becomes
        // (55,55,26). Alpha would lighten the letters instead, which reads as
        // a washed-out page rather than a highlight.
        if !page.highlights.isEmpty, !inkOnly {
            context.saveGState()
            context.setBlendMode(.multiply)
            for highlight in page.highlights {
                let rgb = highlight.rgb
                context.setFillColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
                for rectangle in highlight.rectangles {
                    // A rectangle arrives in the page's coordinates, counted
                    // from the top; the context counts from the bottom.
                    let topLeft = convert(x: rectangle.minX, y: rectangle.minY, pageSize: pageSize)
                    context.fill(
                        CGRect(
                            x: topLeft.x,
                            y: topLeft.y - rectangle.height,
                            width: rectangle.width,
                            height: rectangle.height
                        )
                    )
                }
            }
            context.restoreGState()
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)

        // The images share the scene's sequence with the strokes, and the
        // z-order is the sequence: an image can lie over some strokes and
        // under others. `strokesBefore` is its place in that sequence.
        let placed = strokes(of: page, geometry: geometry)
        let placedImages = inkOnly ? [] : images(of: page, geometry: geometry)
        // The strokes from `split` on are written apart (`writeInk`); they
        // come after everything drawn here, so what is drawn here is the
        // page up to them.
        let split = min(inkSplit ?? placed.count, placed.count)
        var nextImage = 0
        func drawImages(before position: Int) {
            while nextImage < placedImages.count,
                  placedImages[nextImage].strokesBefore <= position {
                drawImage(placedImages[nextImage], images: pictures, in: context, pageSize: pageSize)
                nextImage += 1
            }
        }

        let erasers = split > 0 ? Self.erasers(of: placed, pageSize: pageSize) : []
        // The pieces an eraser left of one shader stroke share a layer: drawn
        // opaque inside it, and the layer is darkened onto the page once at
        // the stroke's own alpha, so the pieces read as the one stroke they
        // were and do not deepen where they meet. They are kept together by
        // `sourceId` — and only they are: two shader strokes that merely
        // cross do deepen in an export,
        // a band of `opacity 0.4` going to `0.57` where two meet and `0.69`
        // where three do (an SVG export of a live page).
        //
        // Anything else between them — another tool, another source, a
        // picture — closes the layer: the z-order is the sequence, and a layer
        // reaching past a pen line would lift the shader over it.
        var sharedLayer: SceneItemID?
        func closeSharedLayer() {
            guard sharedLayer != nil else { return }
            context.endTransparencyLayer()
            context.restoreGState()
            sharedLayer = nil
        }
        for (position, stroke) in placed.enumerated().prefix(split) {
            if nextImage < placedImages.count, placedImages[nextImage].strokesBefore <= position {
                closeSharedLayer()
            }
            drawImages(before: position)
            let layer = sharedLayerKey(of: stroke)
            if layer != sharedLayer {
                closeSharedLayer()
                if let layer {
                    context.saveGState()
                    context.setBlendMode(.darken)
                    context.setAlpha(stroke.alpha)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    sharedLayer = layer
                }
            }
            paint(
                of: stroke, at: position, pageSize: pageSize, erasers: erasers, inSharedLayer: layer != nil
            )?.draw(in: context, masks: masks)
        }
        closeSharedLayer()
        drawImages(before: Int.max)
    }

    /// The bands of a page's erasers, each with its place in the sequence.
    ///
    /// What the erasers take off, cut out of the ink rather than painted
    /// over it.
    ///
    /// Painting is what a blend mode would do, and there is no blend mode
    /// for it here: `destinationOut` is not one of the modes a PDF carries,
    /// and CoreGraphics drops it without a word, so the page would come
    /// out unchanged. White paint is no answer either, because the
    /// eraser leaves the template alone and white would cover it. So the
    /// ink is cut: the band an eraser laid down is subtracted from the
    /// outline of every stroke drawn **before** it, and a stroke drawn
    /// after is untouched, exactly as on the tablet.
    ///
    /// Only tool 6. The area eraser is tool 8 and takes nothing off — its
    /// page in a Move export of `Fixture 13` came back whole where the
    /// other came back with half the ink gone.
    private static func erasers(of placed: [Stroke], pageSize: CGSize) -> [(position: Int, band: CGPath)] {
        placed.enumerated().compactMap { position, stroke in
            stroke.tool == .eraser && stroke.points.count > 1
                ? (position: position, band: outline(of: stroke, pageSize: pageSize))
                : nil
        }
    }

    /// What the stroke at `position` paints, less whatever the erasers after
    /// it took off.
    private static func paint(
        of stroke: Stroke,
        at position: Int,
        pageSize: CGSize,
        erasers: [(position: Int, band: CGPath)],
        inSharedLayer: Bool
    ) -> StrokePaint? {
        // Only the erasers that could have reached this stroke. A page with
        // an eraser in one corner should draw the other corner exactly as a
        // page without one: cutting is a different path through the drawing
        // — a stroked tool has to become a filled outline to have anything
        // to cut — and a stroke nobody erased must not take it.
        let reach = erasers.isEmpty ? .null : coveredBox(of: stroke, pageSize: pageSize)
        return paint(
            of: stroke,
            pageSize: pageSize,
            erasedBy: erasers
                .filter { $0.position > position && $0.band.boundingBox.intersects(reach) }
                .map(\.band),
            inSharedLayer: inSharedLayer
        )
    }

    /// Where a page's ink can be written apart from CoreGraphics' drawing:
    /// the position of the first stroke after the last thing only
    /// CoreGraphics draws — a picture, or a stroke in a shared layer. The
    /// strokes from there on come after everything else on the page, so
    /// they can be written after it (`writeInk`) and the page paints the
    /// same. The page's count when nothing can be.
    static func inkSplit(of placed: [Stroke], images placedImages: [PageImage]) -> Int {
        var split = 0
        for image in placedImages {
            // Drawn before the stroke at `strokesBefore`, or after them all.
            split = max(split, min(max(image.strokesBefore, 0), placed.count))
        }
        for (position, stroke) in placed.enumerated() where sharedLayerKey(of: stroke) != nil {
            split = max(split, position + 1)
        }
        return split
    }

    /// The strokes of a page from `split` on, written into `stream` — the
    /// part of `draw` that `draw(…inkSplit:)` leaves out, painting what it
    /// would have painted. `geometry` is the page's typed text laid out, as
    /// `draw` is handed it.
    static func writeInk(
        _ page: RMPage,
        into stream: InkStream,
        pageSize: CGSize,
        geometry: TextGeometry?,
        from split: Int
    ) {
        let placed = strokes(of: page, geometry: geometry)
        guard split < placed.count else { return }
        let erasers = erasers(of: placed, pageSize: pageSize)
        for (position, stroke) in placed.enumerated().dropFirst(split) {
            paint(of: stroke, at: position, pageSize: pageSize, erasers: erasers, inSharedLayer: false)?
                .write(into: stream)
        }
    }

    /// Which shared layer a stroke goes into, or `nil` when it is drawn on its
    /// own: a shader stroke the eraser cut, one layer per source it was cut
    /// from.
    static func sharedLayerKey(of stroke: Stroke) -> SceneItemID? {
        guard stroke.tool == .shader, stroke.points.count > 1 else { return nil }
        return stroke.sourceId
    }

    /// The rectangle a stroke's ink can touch: its points, spread by the widest
    /// band it carries — and, for a square end, by the reach of its corner,
    /// which a diagonal stroke carries √2 of the half width along each axis;
    /// for a mitred join, by the longest mitre the limit lets through.
    private static func coveredBox(of stroke: Stroke, pageSize: CGSize) -> CGRect {
        let widest = stroke.points.map(\.width).max() ?? 0
        let square: CGFloat = stroke.end == .square ? 2.squareRoot() : 1
        let mitre: CGFloat = stroke.tool?.lineJoin == .miter ? CGFloat(PenTool.lineMiterLimit) : 1
        let corner = max(square, mitre)
        let half = CGFloat(Double(widest) / InkScale.unitsPerRawWidth) / 2 * corner + 1
        var box = CGRect.null
        for point in stroke.points {
            let location = convert(point, pageSize: pageSize)
            box = box.union(
                CGRect(x: location.x - half, y: location.y - half, width: half * 2, height: half * 2)
            )
        }
        return box
    }

    /// The band a stroke lays on the page, as a path in page coordinates.
    private static func outline(of stroke: Stroke, pageSize: CGSize) -> CGPath {
        let path = CGMutablePath()
        for element in StrokeOutline.elements(of: stroke) {
            switch element {
            case .move(let point):
                path.move(to: convert(point, pageSize: pageSize))
            case .line(let point):
                path.addLine(to: convert(point, pageSize: pageSize))
            case .curve(let control1, let control2, let to):
                path.addCurve(
                    to: convert(to, pageSize: pageSize),
                    control1: convert(control1, pageSize: pageSize),
                    control2: convert(control2, pageSize: pageSize)
                )
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    /// The same for a stroke drawn as a line rather than as a contour: the
    /// line turned into the shape it covers, so that something can be cut out
    /// of it.
    private static func strokedOutline(of stroke: Stroke, pageSize: CGSize) -> CGPath {
        let line = CGMutablePath()
        for (index, point) in stroke.points.enumerated() {
            let location = convert(point, pageSize: pageSize)
            if index == 0 { line.move(to: location) } else { line.addLine(to: location) }
        }
        // The cap and the join are the tool's, as the stroked branch draws
        // them: the erased
        // stroke has to differ from the untouched one in the hole and in
        // nothing else.
        return line.copy(
            strokingWithWidth: stroke.lineWidth, lineCap: stroke.end.lineCap,
            lineJoin: stroke.tool?.lineJoin ?? .round, miterLimit: CGFloat(PenTool.lineMiterLimit)
        )
    }

    /// What one stroke paints, worked out once and painted by either of the
    /// two that paint a page's ink: CoreGraphics (`draw(in:masks:)`), or the
    /// writer that writes it in CoreGraphics' place (`write(into:)`). The
    /// decisions — which shape, which colour, cut by which erasers — are
    /// made here, so the two cannot come to paint different things.
    struct StrokePaint {
        enum Shape {
            /// A contour filled, nonzero.
            case fill(CGPath)
            /// A pencil: the contour is the clip, the mask decides which units
            /// inside it are graphite and which are paper, laid over
            /// `rectangle`.
            case mask(clip: CGPath, bits: StrokeGrainMask.Bits, rectangle: CGRect)
            /// A stroked line through the points.
            case line(points: [CGPoint], width: Double, cap: CGLineCap, join: CGLineJoin)
        }

        let shape: Shape
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        let darkens: Bool
        /// Inside a shared layer the blend and the alpha are the layer's, put
        /// on once when it is composited; a stroke drawn there is opaque.
        let inSharedLayer: Bool

        /// The stroke painted by CoreGraphics, call for call as it always
        /// was. `masks` is the document's record of grain masks where part
        /// of its ink is written apart (`InkMaskLedger`).
        func draw(in context: CGContext, masks: InkMaskLedger? = nil) {
            context.saveGState()
            // Darken rather than an alpha, for the highlighter and the shader:
            // that is what exported PDFs declare, and it is what leaves
            // the text under the band alone instead of washing it out.
            if !inSharedLayer {
                if darkens { context.setBlendMode(.darken) }
                context.setAlpha(alpha)
            }
            switch shape {
            case .fill(let path):
                context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
                context.addPath(path)
                context.fillPath(using: .winding)
            case .mask(let clip, _, _) where clip.isEmpty:
                // A contour of nothing: nothing to paint. Clipping to it
                // would clip nothing away and draw the whole mask.
                break
            case .mask(let clip, let bits, let rectangle):
                context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
                if let mask = StrokeGrainMask.image(of: masks?.drawn(bits) ?? bits) {
                    // Nothing is interpolated: a texel is a unit of the page,
                    // and a blurred texel is a grey that an export never
                    // draws.
                    context.addPath(clip)
                    context.clip()
                    context.interpolationQuality = .none
                    context.draw(mask, in: rectangle)
                } else {
                    context.addPath(clip)
                    context.fillPath(using: .winding)
                }
            case .line(let points, let width, let cap, let join):
                context.setStrokeColor(red: red, green: green, blue: blue, alpha: 1)
                context.setLineWidth(width)
                context.setLineCap(cap)
                context.setLineJoin(join)
                context.setMiterLimit(CGFloat(PenTool.lineMiterLimit))
                context.beginPath()
                for (index, point) in points.enumerated() {
                    if index == 0 {
                        context.move(to: point)
                    } else {
                        context.addLine(to: point)
                    }
                }
                context.strokePath()
            }
            context.restoreGState()
        }

        /// The stroke written in CoreGraphics' place, painting what `draw`
        /// paints. Never inside a shared layer: a layer is CoreGraphics'
        /// (`inkSplit(of:images:)`).
        func write(into stream: InkStream) {
            switch shape {
            case .fill(let path):
                stream.fill(path, red: red, green: green, blue: blue, alpha: alpha, darkens: darkens)
            case .mask(let clip, let bits, let rectangle):
                stream.mask(
                    bits, in: rectangle, clip: clip, red: red, green: green, blue: blue, alpha: alpha, darkens: darkens
                )
            case .line(let points, let width, let cap, let join):
                stream.stroke(
                    points, width: width, cap: cap, join: join, miterLimit: PenTool.lineMiterLimit,
                    red: red, green: green, blue: blue, alpha: alpha, darkens: darkens
                )
            }
        }
    }

    /// What one stroke paints, exactly as the loop above draws it in place,
    /// less whatever the erasers drawn after it took off; `nil` where it
    /// paints nothing.
    private static func paint(
        of stroke: Stroke,
        pageSize: CGSize,
        erasedBy erasers: [CGPath],
        inSharedLayer: Bool
    ) -> StrokePaint? {
        guard stroke.points.count > 1 else { return nil }
        // Do not paint the eraser: its stroke looks like ink, and drawing it
        // would cover the page where the user was rubbing out. The taking-off
        // is in `draw`, by subtracting this band from strokes laid down
        // before it. For example, on a Move export of `Fixture 13`, the page
        // with a band crossed by an eraser came back with half our ink, and the
        // half missing is exactly the band under the eraser. The area eraser
        // (tool 8) is the other way about: its page came back whole, so it
        // takes nothing off.
        //
        // Taken off rather than painted over: white would cover the template
        // too, and the eraser leaves the template alone.
        if stroke.tool?.isEraser == true { return nil }
        let rgb = stroke.rgb
        func painted(_ shape: StrokePaint.Shape) -> StrokePaint {
            StrokePaint(
                shape: shape, red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: stroke.alpha,
                darkens: stroke.blend.darkens, inSharedLayer: inSharedLayer
            )
        }

        if !stroke.isStroked || !erasers.isEmpty {
            // A filled contour, the way an export draws seven tools of
            // nine. One fill for the whole stroke, or a translucent tool
            // would darken at every overlap of its own pieces.
            //
            // The two stroked tools come through here as well when
            // something erased them: a line has no shape to cut a hole in, so
            // it is turned into the band it covers first.
            var shape = stroke.isStroked
                ? strokedOutline(of: stroke, pageSize: pageSize)
                : outline(of: stroke, pageSize: pageSize)
            for eraser in erasers { shape = shape.subtracting(eraser) }
            // Erased entirely — or a contour of nothing to begin with: the
            // stroke paints nothing. It must not go on as a clip: CoreGraphics
            // clips to nothing only where there is a path, and a pencil
            // stroke an eraser took away whole came out as the full rectangle
            // of its grain. A contour of no area still has its elements, and
            // clips to nothing as it should, so only a path of none is left
            // out here.
            if shape.isEmpty { return nil }
            let grain = stroke.grain
            if grain != .solid,
               let box = StrokeGrainMask.box(of: stroke),
               let bits = StrokeGrainMask.bits(for: stroke, grain: grain, in: box) {
                // The pencils: the contour still decides the edge — it is the
                // clip — and the mask decides which units inside it are
                // graphite and which are paper.
                let corner = convert(x: box.minX, y: box.maxY, pageSize: pageSize)
                return painted(.mask(
                    clip: shape,
                    bits: bits,
                    rectangle: CGRect(x: corner.x, y: corner.y, width: box.width, height: box.height)
                ))
            }
            return painted(.fill(shape))
        }
        // A stroked line: what an export does with the fineliner and
        // the highlighter, and cheaper than a contour for the same picture.
        return painted(.line(
            points: stroke.points.map { convert($0, pageSize: pageSize) },
            width: stroke.lineWidth,
            cap: stroke.end.lineCap,
            join: stroke.tool?.lineJoin ?? .round
        ))
    }

    /// An image on the page, placed by its four vertices.
    ///
    /// The vertices map the texture onto the sheet: `(x, y)` says where a
    /// corner stands, `(u, v)` which point of the image is pinned there — so
    /// one and the same quad moves, scales, crops and turns. The transform is
    /// solved on three corners; the fourth follows, because the format writes
    /// parallelograms (indexes `0 1 2 2 3 0`).
    ///
    /// An image whose bytes are missing, or do not decode, leaves a hole and
    /// a log line — the document still comes out.
    private static func drawImage(
        _ image: PageImage,
        images: PageImages,
        in context: CGContext,
        pageSize: CGSize
    ) {
        guard image.vertices.count == 4 else { return }
        let decoded: CGImage
        if let ready = images.decoded[image.file] {
            decoded = ready
        } else {
            guard let data = images.bytes[image.file] else {
                RMRenderLog.pageError(
                    "render: no bytes for an image of the page — a hole where it stood"
                )
                return
            }
            guard let fresh = decodeImage(data) else {
                RMRenderLog.pageError(
                    "render: the bytes of an image of the page do not decode — a hole where it stood"
                )
                return
            }
            decoded = fresh
        }
        let v = image.vertices
        let p0 = convert(x: v[0].x, y: v[0].y, pageSize: pageSize)
        let p1 = convert(x: v[1].x, y: v[1].y, pageSize: pageSize)
        let p2 = convert(x: v[2].x, y: v[2].y, pageSize: pageSize)
        let p3 = convert(x: v[3].x, y: v[3].y, pageSize: pageSize)

        // The affine map (u, v) → point: basis vectors from two edges.
        let du1 = v[1].u - v[0].u, dv1 = v[1].v - v[0].v
        let du3 = v[3].u - v[0].u, dv3 = v[3].v - v[0].v
        let det = du1 * dv3 - du3 * dv1
        guard abs(det) > .ulpOfOne else { return }
        let alongU = (
            x: (Double(p1.x - p0.x) * dv3 - Double(p3.x - p0.x) * dv1) / det,
            y: (Double(p1.y - p0.y) * dv3 - Double(p3.y - p0.y) * dv1) / det
        )
        let alongV = (
            x: (Double(p3.x - p0.x) * du1 - Double(p1.x - p0.x) * du3) / det,
            y: (Double(p3.y - p0.y) * du1 - Double(p1.y - p0.y) * du3) / det
        )

        context.saveGState()
        // The quad clips: a cropped capture shows only its own part of the
        // texture, and the clip is what enforces that.
        context.beginPath()
        context.addLines(between: [p0, p1, p2, p3])
        context.closePath()
        context.clip()

        // Where uv (0, 0) lands, so the whole texture can be drawn as the
        // unit square of uv space.
        let origin = (
            x: Double(p0.x) - v[0].u * alongU.x - v[0].v * alongV.x,
            y: Double(p0.y) - v[0].u * alongU.y - v[0].v * alongV.y
        )
        context.concatenate(
            CGAffineTransform(
                a: alongU.x, b: alongU.y,
                c: alongV.x, d: alongV.y,
                tx: origin.x, ty: origin.y
            )
        )
        // v counts down the texture and CoreGraphics draws images with their
        // top row at the rectangle's top in a y-up space — one flip settles
        // the two.
        context.translateBy(x: 0, y: 1)
        context.scaleBy(x: 1, y: -1)
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        context.restoreGState()
    }

    /// The pictures a page's images are drawn from, by file name.
    ///
    /// Two ways in, because there are two kinds of caller. A render of a
    /// whole document checks its attachments before it draws a page
    /// (`PageAssets.decoded`), and that check is a decode: the images it made
    /// are handed in as they are, so a picture shown on a hundred pages is
    /// not decoded a hundred and one times. A caller that hands bytes in —
    /// the public entry points here — has them decoded where they are drawn,
    /// as before, a hole and a log line for any that do not.
    struct PageImages: Sendable {
        var decoded: [String: CGImage] = [:]
        var bytes: [String: Data] = [:]
    }

    /// How many pixels an attachment may unpack to before it is refused.
    ///
    /// Compression is why there has to be a number here at all: a few hundred
    /// kilobytes of flat colour is a 30000×30000 PNG, and unpacking one costs
    /// about 3.6 GB. A host may run the drawing in a process that is killed
    /// for memory long before that — so one broken attachment would take
    /// the whole render down rather than leave a hole on one page.
    ///
    /// 64 megapixels is around 256 MB unpacked and about sixteen times a
    /// tablet's panel: a capture or an insertion cannot reach it.
    static let maximumImagePixels = 64_000_000

    /// How many bytes of attachments one document may hold at once.
    ///
    /// The pixel ceiling above guards the unpacking; this guards the holding.
    /// Attachments are fetched into a dictionary before a single page is
    /// drawn, so a document listing a hundred large ones costs their sum in
    /// the extension before the ceiling is ever consulted. Whatever does not
    /// fit leaves a hole on its page, which is the same outcome as bytes that
    /// failed to download — a case the drawing already knows how to survive.
    public static let maximumAssetBytes = 256 << 20

    /// The attachment's bytes as an image. PNG and JPEG are what the format
    /// carries — captures as PNG, insertions as what was inserted.
    static func decodeImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let decoded: CGImage?
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            decoded = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        } else if data.starts(with: [0xFF, 0xD8]) {
            decoded = CGImage(
                jpegDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        } else {
            decoded = nil
        }
        guard let image = decoded else { return nil }
        // The measurements come off the header, so this is asked before a
        // single row is unpacked: the picture is rasterized where it is drawn.
        let pixels = image.width.multipliedReportingOverflow(by: image.height)
        guard image.width > 0, image.height > 0,
              !pixels.overflow, pixels.partialValue <= maximumImagePixels
        else {
            RMRenderLog.pageError(
                "render: an image of \(image.width)×\(image.height) is past what is drawn — a hole where it stood"
            )
            return nil
        }
        return image
    }

    /// The marker in front of an item of a list.
    ///
    /// Which of the three ways it is drawn is the family's business, and each
    /// way has its own place on the line: a bullet is a glyph set from the
    /// left, a number is a glyph set to end just before the text, a checkbox
    /// is a drawn box. The gaps are `TypeMetrics` constants that match
    /// exported PDFs.
    private static func drawListMarker(
        _ paragraph: TextGeometry.Paragraph,
        left: Double,
        in context: CGContext,
        pageSize: CGSize
    ) {
        guard let style = paragraph.format?.style, let family = style.listFamily else { return }
        let text = left + paragraph.indent
        let attributes = TextGeometry.attributes(size: paragraph.size, face: paragraph.face)

        func draw(_ label: String, endingAt right: Double?, startingAt start: Double?) {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: label, attributes: attributes)
            )
            let x = start ?? (right ?? 0) - CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = convert(x: x, y: paragraph.baseline, pageSize: pageSize)
            CTLineDraw(line, context)
        }

        switch family {
        case .bullet:
            // A glyph and not a drawn shape, and a different one at every level:
            // `•`, then `◦`, then `–`.
            draw(
                ListMarker.bullet(level: paragraph.level),
                endingAt: nil,
                startingAt: text - TypeMetrics.bulletGap
            )
        case .numbered:
            // Ending just before the text, which is where an export ends it:
            // items at 286 carry numbers ending at 264.5, items at 334 at 312.5.
            draw(
                ListMarker.label(ordinal: paragraph.ordinal, level: paragraph.level),
                endingAt: text - TypeMetrics.markerGap,
                startingAt: nil
            )
        case .checkbox:
            drawCheckbox(
                state: paragraph.checkbox ?? .unticked,
                at: convert(
                    x: text - TypeMetrics.checkboxGap,
                    y: paragraph.baseline,
                    pageSize: pageSize
                ),
                in: context
            )
        }
    }

    /// A checkbox, drawn as a path rather than typed as a glyph: `☐` and `☑`
    /// are missing from the fallback faces. A ticked box is filled with a
    /// white tick inside, as in exported PDFs; the box hangs
    /// `checkboxDrop` below the baseline rather than standing wholly above it.
    private static func drawCheckbox(state: CheckboxState, at baseline: CGPoint, in context: CGContext) {
        let side = TypeMetrics.checkboxSide
        // The context counts y upwards, so dipping below the baseline is a
        // subtraction here and an addition on the page.
        let box = CGRect(
            x: baseline.x,
            y: baseline.y - TypeMetrics.checkboxDrop,
            width: side,
            height: side
        )
        context.saveGState()
        context.setLineWidth(TypeMetrics.checkboxStroke)
        context.setStrokeColor(inkColour)
        context.setFillColor(inkColour)

        switch state {
        case .ticked:
            context.fill(box)
            context.setStrokeColor(paperColour)
            context.beginPath()
            for (position, point) in Calibration.checkboxTick.enumerated() {
                let corner = CGPoint(x: box.minX + side * point.x, y: box.minY + side * point.y)
                if position == 0 { context.move(to: corner) } else { context.addLine(to: corner) }
            }
            context.strokePath()
        case .partial:
            // Some of the nested items ticked and some not: an export draws
            // the empty box with a dash across its middle.
            context.stroke(box)
            let inset = side * Calibration.checkboxDashInset
            context.beginPath()
            context.move(to: CGPoint(x: box.minX + inset, y: box.midY))
            context.addLine(to: CGPoint(x: box.maxX - inset, y: box.midY))
            context.strokePath()
        case .unticked:
            context.stroke(box)
        }
        context.restoreGState()
    }

    static let inkColour = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    /// The tick inside a filled checkbox is the paper showing through.
    private static let paperColour = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// What a numbered item is called at its level of nesting.
    ///
    /// The format numbers three levels three ways — `1. 2.`, then `a. b.`,
    /// then `i. ii.` — and each level counts on its own, so the item after a
    /// nested block continues the level it belongs to.
    enum ListMarker {
        /// Which glyph at which level — `Calibration.listBullet`.
        static func bullet(level: Int) -> String { Calibration.listBullet(level: level) }

        /// The numbering scheme comes from `Calibration`; the spelling of the
        /// label is decided here.
        static func label(ordinal: Int, level: Int) -> String {
            switch Calibration.listNumbering(level: level) {
            case .decimal: "\(ordinal)."
            case .letter: "\(letter(ordinal))."
            case .roman: "\(roman(ordinal))."
            }
        }

        /// `a … z`, then `aa`, `ab` — the spreadsheet's way, which is what a
        /// list of more than twenty-six items needs.
        private static func letter(_ ordinal: Int) -> String {
            var value = max(ordinal, 1)
            var text = ""
            while value > 0 {
                let index = (value - 1) % 26
                text = String(UnicodeScalar(UInt8(97 + index))) + text
                value = (value - 1) / 26
            }
            return text
        }

        private static func roman(_ ordinal: Int) -> String {
            let table: [(Int, String)] = [
                (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
                (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
            ]
            var value = max(ordinal, 1)
            var text = ""
            for (number, sign) in table {
                while value >= number {
                    text += sign
                    value -= number
                }
            }
            return text
        }
    }

    /// The page's strokes in the sheet's own coordinates.
    ///
    /// Handwriting anchored to typed text arrives from the parser counted from
    /// its paragraph, because where that paragraph lands is not known until the
    /// text has been laid out. Everything else comes through untouched.
    ///
    /// Here rather than at the call sites, so that no route to the paper can
    /// forget it: the notebook renderer and the one that draws marks onto an
    /// imported PDF both go through `draw`, and the sheet is sized by
    /// `contentBounds`, which asks the same question of the same geometry.
    private static func strokes(of page: RMPage, geometry: TextGeometry?) -> [Stroke] {
        // Drawn widths before placing: what is measured against the export
        // is the ink as the export has it, and the bounds of the sheet are
        // read off the same strokes that are drawn.
        let drawn = page.strokes.map(\.drawn)
        guard let geometry else { return drawn }
        return geometry.placing(drawn)
    }

    /// The same strokes, for measuring rather than for drawing.
    ///
    /// Public on purpose: where anchored handwriting lands is a matter of
    /// the layout, and the only way to check it against an exported PDF
    /// is to ask the renderer itself. Reading the coordinates out of
    /// `RMPage.strokes` instead answers with the file's own, which for anchored
    /// handwriting is not where it goes.
    public static func placedStrokes(of page: RMPage, pageSize: CGSize = defaultPageSize) -> [Stroke] {
        strokes(of: page, geometry: page.text.map { TextGeometry($0, pageSize: pageSize) })
    }

    /// The page's images in the sheet's own coordinates, for the same two
    /// readers as `strokes(of:geometry:)`: the drawing, and the sheet
    /// measurement. An image fastened to the text counts its vertices from
    /// the pen at its anchor, and only the layout knows where that is.
    private static func images(of page: RMPage, geometry: TextGeometry?) -> [PageImage] {
        guard let geometry else { return page.images }
        return geometry.placing(page.images)
    }

    /// The images as they land, for measuring rather than for drawing — the
    /// image half of `placedStrokes`, public for the same reason.
    public static func placedImages(of page: RMPage, pageSize: CGSize = defaultPageSize) -> [PageImage] {
        images(of: page, geometry: page.text.map { TextGeometry($0, pageSize: pageSize) })
    }

    /// The width our own faces give a string.
    ///
    /// Public for the calibration: an exported PDF states the advance
    /// of every glyph it sets, and the only way to tell how far our substitutes
    /// are from those is to measure the same string with both.
    public static func textWidth(
        _ string: String,
        size: Double,
        face: TypeFace,
        bold: Bool = false,
        italic: Bool = false,
        lessRightmostGlyph: Bool = false
    ) -> Double {
        // Built through the same attribute assembly as the layout, so the
        // measurement measures the very font the text is later set in.
        let attributed = NSMutableAttributedString(string: string)
        TextGeometry.apply(
            size: size, face: face, bold: bold, italic: italic,
            to: attributed, range: NSRange(location: 0, length: attributed.length)
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard lessRightmostGlyph else { return width }
        // The glyph that reaches farthest right, by where it ends rather
        // than where it starts: a mark sits past its base's origin with a
        // negative advance that steps back, and by origin alone it would
        // win. Exported PDFs state the advance **between** glyphs,
        // so the far glyph of every line leaves none — and for a line set
        // right to left that is the first glyph typed, for Devanagari the
        // last one drawn rather than the last one stored; the shaped line
        // is the one place both are the same glyph.
        var farthest = 0.0
        var advance = 0.0
        let units = Array(string.utf16)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for index in 0..<count where advances[index].width > 0 {
                // A mark never ends a line's extent in an export,
                // so it must not be the glyph taken off on ours.
                let unit = indices[index] < units.count ? units[indices[index]] : 0
                if let scalar = Unicode.Scalar(UInt32(unit)),
                   scalar.properties.generalCategory == .nonspacingMark {
                    continue
                }
                let end = positions[index].x + advances[index].width
                if end > farthest {
                    farthest = end
                    advance = advances[index].width
                }
            }
        }
        return width - advance
    }

    /// One visual line of typed text, in the units an exported PDF
    /// states: which paragraph it belongs to, the characters it covers, and
    /// where it sits and ends on the sheet.
    public struct TextLine: Sendable {
        public let paragraph: Int
        public let from: Int
        public let to: Int
        public let baseline: Double
        public let start: Double
        public let end: Double
    }

    /// The typed text as it was laid out: one entry per visual line.
    ///
    /// Public for the same reason as `placedStrokes` — an exported PDF
    /// states these numbers outright, and the end of a line is where the
    /// handwriting anchored to it begins.
    public static func textLines(
        of page: RMPage,
        pageSize: CGSize = defaultPageSize
    ) -> [TextLine] {
        guard let text = page.text else { return [] }
        let geometry = TextGeometry(text, pageSize: pageSize)
        return geometry.paragraphs.flatMap { paragraph in
            paragraph.lines.compactMap { visual in
                guard let typesetter = paragraph.typesetter else { return nil }
                let line = CTTypesetterCreateLine(typesetter, visual.range)
                let start = geometry.margin(of: paragraph, line: line)
                return TextLine(
                    paragraph: paragraph.number,
                    from: visual.range.location,
                    to: visual.range.location + visual.range.length,
                    baseline: visual.baseline,
                    start: start,
                    end: start + CTLineGetTypographicBounds(line, nil, nil, nil)
                )
            }
        }
    }

    /// Draw the typed text off the layout worked out for it. All baseline
    /// arithmetic lives in `TextGeometry`; only the drawing is left here.
    ///
    /// CoreText rather than `showText`: the latter goes through single-byte
    /// encodings and cannot set Cyrillic. The text matrix is deliberately
    /// left at identity: `convert` has already moved the *position* into the
    /// context's coordinates, and the glyphs are upright in them — flipping
    /// the matrix as well would turn the text upside down.
    private static func draw(_ geometry: TextGeometry, in context: CGContext, pageSize: CGSize) {
        context.saveGState()
        context.textMatrix = .identity

        for paragraph in geometry.paragraphs {
            let style = paragraph.format?.style
            drawListMarker(paragraph, left: geometry.left, in: context, pageSize: pageSize)

            // An empty paragraph is still a line: the three empty checkboxes
            // of a live page are exactly this. It has no typesetter and
            // nothing to draw, and it has taken its step already.
            guard let typesetter = paragraph.typesetter else { continue }

            for visual in paragraph.lines {
                let line = CTTypesetterCreateLine(typesetter, visual.range)
                let lineStart = convert(
                    x: geometry.margin(of: paragraph, line: line),
                    y: visual.baseline,
                    pageSize: pageSize
                )
                context.textPosition = lineStart
                CTLineDraw(line, context)
                if paragraph.checkbox == .ticked {
                    // A done item is struck through, as in exported PDFs. Drawn rather than asked of CoreText: an
                    // attribute would have to be applied to the string, and
                    // the string here is shared with the line breaking.
                    // From where the line began, not from where the drawing
                    // left the pen: `textPosition` has advanced to the end of
                    // the line by now, and striking from there draws a rule
                    // into the empty right margin.
                    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                    let rule = lineStart.y + paragraph.size * Calibration.strikeHeight
                    context.saveGState()
                    context.setStrokeColor(inkColour)
                    // The floor keeps the rule visible in print, same
                    // requirement as the minimum stroke width.
                    context.setLineWidth(max(paragraph.size * Calibration.strikeWeight, 0.6))
                    context.beginPath()
                    context.move(to: CGPoint(x: lineStart.x, y: rule))
                    context.addLine(to: CGPoint(x: lineStart.x + CGFloat(width), y: rule))
                    context.strokePath()
                    context.restoreGState()
                }
            }
        }
        context.restoreGState()
    }

    /// The rectangle that has to land on the sheet: the page itself and
    /// everything drawn beyond it.
    ///
    /// The page is always included, otherwise a short note in a corner would
    /// give a sheet the size of that note, with no margins and no template
    /// around it.
    static func contentBounds(
        of page: RMPage,
        pageSize: CGSize,
        edge: InkEdge,
        geometry laidOut: TextGeometry? = nil
    ) -> CGRect {
        let sheet = CGRect(origin: .zero, size: pageSize)
        var bounds = sheet
        // The same layout the drawing uses, and for the same two reasons: the
        // handwriting anchored to the text has to be positioned where it will be
        // drawn, and the text's own depth is a matter of how often it wraps.
        // Handed in where the caller goes on to draw, so it is laid out once.
        let geometry = laidOut ?? page.text.map { TextGeometry($0, pageSize: pageSize) }
        // The deepest centreline, kept apart from `bounds`. What carries a
        // sheet downwards is where the pen went, not how wide its band was:
        // a stroke that ends on the last unit of the page puts half a ribbon
        // past the edge, and an export does not grow the sheet for it.
        var deepest: Double?
        /// The centreline's reach to either side and upwards, kept for the same
        /// reason as `deepest`: what moves a sheet is where the pen went.
        var leftmost: Double?
        var rightmost: Double?
        var highest: Double?
        for stroke in strokes(of: page, geometry: geometry) {
            // The eraser is not drawn, and it has no business widening the
            // sheet.
            if stroke.tool?.isEraser == true { continue }
            for point in stroke.points {
                let location = convert(point, pageSize: pageSize)
                deepest = min(deepest ?? location.y, location.y)
                highest = max(highest ?? location.y, location.y)
                leftmost = min(leftmost ?? location.x, location.x)
                rightmost = max(rightmost ?? location.x, location.x)
                // The points are the centreline; the pen lays a band of
                // its own width around it.
                let half = edge.halfWidth(at: point)
                bounds = bounds.union(
                    CGRect(
                        x: location.x - half,
                        y: location.y - half,
                        width: half * 2,
                        height: half * 2
                    )
                )
            }
        }

        // An image widens the sheet the way ink does: a capture placed past
        // the edge would otherwise be clipped off silently.
        for image in images(of: page, geometry: geometry) {
            for vertex in image.vertices {
                let corner = convert(x: vertex.x, y: vertex.y, pageSize: pageSize)
                bounds = bounds.union(CGRect(origin: corner, size: .zero))
                // Counted as a centreline as well, and not only into `bounds`:
                // the edge rules below cut whatever hangs over an edge that the
                // ink itself did not cross, and an image is not a band around
                // a line — its corner is where it ends. Left out, a capture
                // placed past the edge would be trimmed away by a rule meant
                // for the ribbon of a pen.
                deepest = min(deepest ?? corner.y, corner.y)
                highest = max(highest ?? corner.y, corner.y)
                leftmost = min(leftmost ?? corner.x, corner.x)
                rightmost = max(rightmost ?? corner.x, corner.x)
            }
        }

        // Typed text can run past the bottom of the page just as handwriting
        // can, and a page of nothing but text would otherwise take its bounds
        // from its strokes alone — of which there are none.
        if let text = page.text, let geometry, let frame = geometry.frameBottom {
            bounds = bounds.union(
                CGRect(origin: convert(x: text.originX, y: text.originY, pageSize: pageSize), size: .zero)
            )
            // The column counts sideways the way the pen does: a column wider
            // than the sheet takes the square sheet below, the same one ink
            // past the edge takes. Inferred from one page and its export: on a
            // Move in automatic reflow, a 936 column laid from −370 on an 820
            // canvas exports the page 1458 wide, the column's origin 359 units in from the left — the
            // square, centred. Other layouts that overflow are untested. A
            // column inside the sheet changes nothing here.
            if let width = text.columnWidth {
                let left = convert(x: text.originX, y: text.originY, pageSize: pageSize).x
                let right = convert(x: text.originX + width, y: text.originY, pageSize: pageSize).x
                leftmost = min(leftmost ?? left, left)
                rightmost = max(rightmost ?? right, right)
            }
            let bottom = convert(x: text.originX, y: frame, pageSize: pageSize).y
            // The sheet follows the text's frame the way it follows the ink:
            // only once the frame is past the edge by more than the foot, and
            // then to the frame plus the foot. A frame three units over the
            // edge leaves the exported sheet as it is; frames further over
            // come back exactly a foot below themselves.
            switch edge {
            case .ribbon:
                if bottom < sheet.minY - InkEdge.textFoot {
                    bounds = bounds.union(CGRect(x: bounds.minX, y: bottom - InkEdge.textFoot, width: 0, height: 0))
                } else {
                    bounds = bounds.union(CGRect(x: bounds.minX, y: max(bottom, sheet.minY), width: 0, height: 0))
                }
            case .uncut:
                // The same foot, with no threshold: a frame past the edge by
                // any amount carries the sheet.
                if bottom < sheet.minY {
                    bounds = bounds.union(CGRect(x: bounds.minX, y: bottom - InkEdge.textFoot, width: 0, height: 0))
                }
            case .centreline:
                bounds = bounds.union(CGRect(x: bounds.minX, y: bottom, width: 0, height: 0))
            }
        }

        // A sheet carried downwards by the ink keeps a foot of blank below the
        // last point, matching exported PDFs; without it the sheet
        // would end flush against the ribbon instead.
        //
        // Sideways there is no foot at all, and no following the ink either:
        // the sheet becomes the square — side = the canvas height — and stops
        // there, whatever the pen did. For example, on a notebook drawn for it,
        // one page whose ink stopped short of the edge at ±987 and one whose
        // ink ran out to +1559 both came back exactly 2160 wide, the second
        // with its far ink simply cut off. So this sets the width rather than
        // widening to it.
        var squared = false
        if edge.hugsTheRibbon, let leftmost, let rightmost,
           leftmost < sheet.minX || rightmost > sheet.maxX {
            let square = max(pageSize.width, pageSize.height)
            bounds.origin.x = (pageSize.width - square) / 2
            bounds.size.width = square
            squared = true
        }
        // `minY`, not `maxY`: here the axis runs upwards, so the sheet carried
        // downwards is the one whose bottom has gone below the page's — the
        // same edge the `.centreline` block below extends by its margin.
        // Whether it grows is decided by the centreline; how far, by the
        // ribbon. Both halves hold against exported PDFs: a stroke
        // ending on the last unit of the page hangs half a band over the
        // edge and does not grow the sheet at all, while a sheet that does
        // grow clears the drawn band — not its centre — by the foot.
        // And it has to be past the edge by more than the foot itself before
        // anything happens: for example, on four pages drawn to order, ink 40
        // units below the page left the sheet exactly as it was, while 80,
        // 160 and 240 all grew to the ink plus the foot. The two live
        // readings fall on the same side of that line — 32 did not grow, 270
        // did.
        //
        // Which reads as the export keeping a foot of clearance rather than
        // adding one: while the ink is nearer the bottom than that, the page
        // already provides it, and only ink that would eat into the clearance
        // moves the edge.
        if case .ribbon = edge, let deepest {
            if deepest < sheet.minY - InkEdge.foot {
                bounds.origin.y -= InkEdge.foot
                bounds.size.height += InkEdge.foot
            } else if bounds.minY < sheet.minY {
                // Near enough to the edge that the sheet does not move — so
                // the ink that hangs over it is cut, not accommodated. Without
                // this the overhanging half-band would grow the page by its
                // own width: a stroke 40 units below would come out 34 units
                // too tall where the export gives the plain sheet.
                bounds.size.height -= sheet.minY - bounds.minY
                bounds.origin.y = sheet.minY
            }
        }
        // Uncut: the ribbon already reaches wherever the pen went; a sheet
        // the pen carried past the edge keeps the same foot of clearance
        // under it, whatever the distance.
        if case .uncut = edge, let deepest, deepest < sheet.minY {
            bounds.origin.y -= InkEdge.foot
            bounds.size.height += InkEdge.foot
        }

        // The other three edges follow the rule the bottom one follows: ink
        // whose centreline stayed on the page cannot carry the sheet past it,
        // so the half-band hanging over is cut rather than accommodated.
        //
        // For example, with a frame drawn along the page's own edges
        // (`Fixture 28`, exported from a Move): the export gives the plain
        // sheet, 820 units wide, where an uncut ribbon would give 823 — half
        // a stroke over each edge the frame stands on. The same three units
        // show on the turned page and on the corner squares of `Fixture 30`,
        // and on the page where the frame stands 47 units inside the edge
        // both sides agree, which is what says the difference is the
        // overhang and not the sheet.
        //
        // Not sideways once the sheet is the square: the pen crossed one
        // side, and the square's margin on the other side is the window's
        // own, not an overhang. Cutting it there would give a page written
        // past its right edge a sheet 1139 wide with the canvas pressed to
        // the left, where exported PDFs show the same page centred on the
        // square, 1458 wide. The top is
        // a different edge and keeps its rule either way.
        if case .ribbon = edge {
            if !squared, let leftmost, leftmost >= sheet.minX, bounds.minX < sheet.minX {
                bounds.size.width -= sheet.minX - bounds.minX
                bounds.origin.x = sheet.minX
            }
            if !squared, let rightmost, rightmost <= sheet.maxX, bounds.maxX > sheet.maxX {
                bounds.size.width -= bounds.maxX - sheet.maxX
            }
            if let highest, highest <= sheet.maxY, bounds.maxY > sheet.maxY {
                bounds.size.height -= bounds.maxY - sheet.maxY
            }
        }

        // The margin is added only along the edges that grew — see `InkEdge`.
        if case .centreline(let margin) = edge {
            if bounds.minX < sheet.minX {
                bounds.origin.x -= margin
                bounds.size.width += margin
            }
            if bounds.maxX > sheet.maxX { bounds.size.width += margin }
            if bounds.minY < sheet.minY {
                bounds.origin.y -= margin
                bounds.size.height += margin
            }
            if bounds.maxY > sheet.maxY { bounds.size.height += margin }
        }
        return bounds
    }

    /// How the edge of the ink is determined when the sheet has to grow.
    ///
    /// Two cases, checked separately against exported PDFs, and
    /// they disagree — hence a choice rather than a constant. A notebook
    /// sheet hugs the drawn ribbon (the stroke width and nothing more); an
    /// annotated PDF grows from the centreline of the points plus a margin.
    enum InkEdge: Sendable {
        /// The blank an export leaves below the last point on a sheet the ink
        /// has carried downwards.
        ///
        /// For example, on an exported seven-page notebook: two pages ran past the bottom, their lowest points at 3818.1
        /// and 4167.2, and the pages came out 3865 and 4215 units tall — 46.9
        /// and 47.8 below the ink. The two disagree by less than the rounding
        /// of the boxes they were read from, which state whole points; one
        /// constant of 47 covers both.
        static let foot: Double = 47

        /// The blank an export leaves under the frame of typed text on a
        /// sheet the text has carried downwards — under the last baseline,
        /// its line's descent and the 24 every paragraph keeps below itself.
        ///
        /// For example, across the eighteen grown pages of the text corpus
        /// (`Fixture 01`…`05` and `10`, exported from a Move): a page ending
        /// in a Latin body line was 64.8…67.1 below its last baseline, in
        /// an Arabic one 79.7, in a heading 67.1…69.0, in a subheading
        /// 58.8…63.8 — each the descent of that line plus 24 plus this, to
        /// within the whole points the page boxes are stated in.
        static let textFoot: Double = 25

        /// The edge of the drawn ribbon and nothing more, trimmed where
        /// exported PDFs trim: ink hanging a little over an edge
        /// is cut, not accommodated.
        case ribbon
        /// The centreline of the points plus a margin along a grown edge.
        case centreline(margin: Double)
        /// The edge of the drawn ribbon, and nothing ever cut: every band
        /// the pen laid is on the sheet, for a bitmap an engine reads or a
        /// person looks at.
        case uncut

        /// How far a point extends to each side.
        func halfWidth(at point: StrokePoint) -> Double {
            switch self {
            case .ribbon, .uncut: point.lineWidth / 2
            case .centreline: 0
            }
        }

        /// Whether the sheet is measured by the ribbon — and so widens to
        /// the square when the pen left the page sideways.
        var hugsTheRibbon: Bool {
            switch self {
            case .ribbon, .uncut: true
            case .centreline: false
            }
        }
    }

    /// A page's coordinates run from the centre horizontally and top to
    /// bottom vertically, while a PDF counts from the bottom left corner.
    static func convert(_ point: StrokePoint, pageSize: CGSize = defaultPageSize) -> CGPoint {
        convert(x: Double(point.x), y: Double(point.y), pageSize: pageSize)
    }

    /// Opens the artifact mark, and says whether it did: only where the
    /// system has the mark to offer.
    ///
    /// Behind a compilation condition and not behind `#available` alone, and
    /// that distinction is the whole point: `#available` is a *runtime* test,
    /// and the compiler must still resolve the symbol against the SDK it is
    /// given. `beginNonStructuralMarkedContentSequence` arrived in the macOS 27
    /// SDK, so a toolchain older than that fails to build this file at all —
    /// which is what happens on every runner image offered today, and is how
    /// CI found it.
    ///
    /// Off by default, therefore: a clone and CI compile without the mark, and
    /// a build that has the SDK opts in.
    ///
    ///     swift build -Xswiftc -DRMRENDER_PDF_TAGGING
    ///
    /// What is lost when it is off is not the drawing but its description: the
    /// ruling is then ordinary content, so a reader that reflows, extracts or
    /// searches the page reads the lines along with the writing.
    private static func markTemplateAsArtifact(in context: CGContext) -> Bool {
        #if RMRENDER_PDF_TAGGING
        guard #available(macOS 27, *) else { return false }
        context.beginNonStructuralMarkedContentSequence(.artifact)
        return true
        #else
        false
        #endif
    }

    /// The same conversion for a point of a stroke's outline.
    static func convert(_ point: CGPoint, pageSize: CGSize = defaultPageSize) -> CGPoint {
        convert(x: Double(point.x), y: Double(point.y), pageSize: pageSize)
    }

    /// The same conversion for a bare pair of coordinates: the text block
    /// gives its origin as one, not as a stroke point.
    static func convert(x: Double, y: Double, pageSize: CGSize = defaultPageSize) -> CGPoint {
        CGPoint(
            x: CGFloat(x) + pageSize.width / 2,
            y: pageSize.height - CGFloat(y)
        )
    }
}
