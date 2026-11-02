// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks
import RMLines

/// Where a stroke lands on a page of an imported PDF.
///
/// Read off exports from the tablet's own app: an export counts in
/// units of about 1/227 inch whatever the model, and the coordinates live in
/// the space of the *page* rather than of the screen. "A unit is a panel
/// pixel" does not hold everywhere — the Move declares a canvas smaller than
/// its panel — so the canvas comes from the file.
///
/// The unit itself is `Calibration.pointsPerUnit`; this type holds only what
/// is derived from it — the sheet, the reverse conversion into units and the
/// frame's place on the page.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum AnnotationGeometry {
    /// The sheet a page inserted on the tablet is drawn on.
    ///
    /// Its size comes from the scene block of that page's own `.rm`, because
    /// the tablet's app does not bring such a page to the format of the
    /// document: an export of a Letter document with two pages added on a
    /// Paper Pro Move carries three Letter sheets and two of 260 × 463 pt.
    /// Normalising them here would move the marks.
    public static func sheet(forScene scene: CGSize) -> CGSize {
        CGSize(width: scene.width * Calibration.pointsPerUnit, height: scene.height * Calibration.pointsPerUnit)
    }

    /// The sheet expressed in `.rm` units — the coordinate space
    /// `PageRenderer.convert` works in, which is what lets the stroke drawing
    /// be shared with notebooks instead of written a second time.
    static func units(of sheet: CGSize) -> CGSize {
        CGSize(width: sheet.width / Calibration.pointsPerUnit, height: sheet.height / Calibration.pointsPerUnit)
    }

    /// The page's own rectangle grown to hold what was written past its edges.
    ///
    /// The tablet lets the pen run off the sheet, and its app exports the page
    /// widened to fit. For example, on a US Letter test page written in
    /// both margins, the export carries `/MediaBox [-207.95 0 858.65 792]`
    /// around an `/ArtBox` that is still the original `[0 0 612 792]`. Keeping
    /// the original's box would let a reader clip 208 pt of the marks on the
    /// left and 247 pt on the right — the ink would be in the file the whole
    /// time and no one could see it.
    ///
    /// `bounds` is what `PageRenderer.contentBounds` computes, in `.rm` units
    /// of a sheet standing at `sheet.origin`; the two conversions here are the
    /// ones `MarkContentStream` writes its coordinates with. A page whose
    /// marks stay on it measures back to `sheet`, and nothing moves.
    static func box(_ bounds: CGRect, on sheet: CGRect) -> CGRect {
        CGRect(
            x: sheet.minX + bounds.minX * Calibration.pointsPerUnit,
            y: sheet.minY + bounds.minY * Calibration.pointsPerUnit,
            width: bounds.width * Calibration.pointsPerUnit,
            height: bounds.height * Calibration.pointsPerUnit
        )
    }
}

/// A PDF with the tablet's marks drawn onto it.
///
/// Without this a caller would serve such a document as its untouched
/// original — the user would open their own PDF and see none of their own
/// marks.
public struct AnnotatedPDFRenderer: Sendable {
    /// Where the bytes come from. Whether anything is cached between renders
    /// is the caller's affair — and it matters: without a cache a book is
    /// downloaded again on every render — for example, 112 MB take 33.8 s of
    /// download against a second of drawing.
    private let blobs: any PageBlobs

    public init(blobs: any PageBlobs) {
        self.blobs = blobs
    }

    /// The document's pages, each the original page with its marks over it,
    /// written into `output`.
    ///
    /// Pages come from `.content`, in its order. A page carrying `redir`
    /// belongs to the imported file and is drawn over that page of it; a page
    /// without `redir` was added on the tablet and has nothing behind it.
    ///
    /// `onProgress` counts work rather than pages: first the bytes of the
    /// original as they arrive, then one unit per page drawn. Pages alone
    /// would leave the bar at nought for the whole download and then race —
    /// on that same book, 33.8 seconds of silence against a second
    /// of drawing.
    ///
    /// A file rather than `Data`, and on a big book that is the difference
    /// between working and being killed: the output of this renderer is about
    /// the size of its input, so a large book collected in memory doubles its
    /// own footprint, and a caller writes the bytes to a file anyway.
    ///
    /// A `redir` the original cannot honour — below zero, at or past its
    /// page count, or not a whole number at all — is a page with no original
    /// behind it, drawn on blank paper like a page added on the tablet; the
    /// render never traps on it. A page `.content` names twice is drawn once,
    /// where it first stands.
    ///
    /// `maximumPages` cuts the document to its first pages, after all of
    /// that: the output never has more, whatever the file says. A cap below
    /// one is taken as one. `onPageCount` is told, once, how many pages will
    /// be drawn and how many the document has before the cut — the
    /// original's page count where `.content` lists nothing.
    ///
    /// A cut that leaves pages out always goes the long way round: the
    /// overlay writes onto the original's own pages, all of them, and a
    /// document shorter than its original is not one it can make. The
    /// output loses the original's links and outline for it.
    ///
    /// A certified original — one whose catalog carries `/Perms` — takes no
    /// incremental update: appending to it would break the certification.
    /// Whenever it is drawn afresh — because there are marks to append, or
    /// for any of the reasons above — the output keeps its links and outline
    /// and not its certification, and `onCertificationDropped` is called once
    /// before the drawing starts. A certified original with no marks on pages
    /// in its own order goes out as it is, certification included, and
    /// nothing is called. `refuseCertified` turns the fresh drawing into a
    /// refusal: the render throws `RenderError.unsupportedFormat` instead and
    /// writes no output.
    ///
    /// A page whose `/UserUnit` is other than 1 is refused with
    /// `RenderError.unsupportedFormat`: neither route scales the marks by it.
    ///
    /// An image the marks place on a page and the drawing cannot show — its
    /// attachment is absent from the index, failed to arrive, is past the
    /// size budget, or holds bytes that do not decode as an image — leaves a
    /// hole where it stood, and the page is drawn without it. The render goes
    /// on, and `onMissingImages` is called once with the number of pages that
    /// lost an image and the number of attachments missing.
    public func renderPDF(
        documentID: String,
        index: DocumentFiles,
        to output: URL,
        // Debugging only: the two routes have to be comparable on one and the
        // same document, and the choice is otherwise made here rather than by
        // the caller.
        allowOverlay: Bool = true,
        // Strict mode for certified originals: see above. Off by default, so
        // that a certified document comes out with its marks drawn.
        refuseCertified: Bool = false,
        author: String? = nil,
        maximumPages: Int? = nil,
        onProgress: @escaping @Sendable (_ completed: Int64, _ total: Int64) -> Void = { _, _ in },
        // Second, after `onProgress`, and of two numbers: see
        // `NotebookRenderer.renderPDF`. A trailing closure still finds
        // `onProgress` forwards and `onUnreadable` backwards.
        onPageCount: @escaping @Sendable (_ drawn: Int, _ document: Int) -> Void = { _, _ in },
        // Two numbers, like `onPageCount`, so that a trailing closure written
        // for `onUnsupported` after an `onPageCount:` label is refused by the
        // compiler rather than taken for this one. See `NotebookRenderer`.
        onMissingImages: @escaping @Sendable (_ pages: Int, _ images: Int) -> Void = { _, _ in },
        // No arguments, so that no closure written for the callbacks around
        // it can be taken for it.
        onCertificationDropped: @escaping @Sendable () -> Void = {},
        // Called at most once, and only when the marks on some of the pages
        // are in an older `.rm` generation. The same division of labour as in
        // `NotebookRenderer`: this renderer knows what it could not read, and
        // the caller decides what the news is worth.
        onUnsupported: @escaping @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @escaping @Sendable (_ pages: Int) -> Void = { _ in }
    ) async throws {
        guard let originalEntry = index.file(withExtension: "pdf") else {
            throw RenderError.malformedPage("an annotated document without its PDF")
        }
        // A size of zero would make the bar meaningless rather than wrong: a
        // record without one is a record we do not trust, and one unit is
        // enough to keep the arithmetic honest.
        //
        // Bounded above as well: the size is the index's word, and the bar
        // adds a unit per page to it — a stated `Int64.max` plus one is a
        // trap. Half of it is past any file there is.
        let originalBytes = min(max(Int64(originalEntry.size), 1), Int64.max / 2)
        let downloaded = try await self.original(originalEntry, owner: documentID) { completed, total in
            onProgress(completed, max(total, originalBytes))
        }
        // A file taken out of the cache belongs to the cache; only our own
        // download is ours to delete. Removing it while CoreGraphics has it
        // mapped would be safe — the bytes live until the last descriptor
        // closes — but it happens at the end of the render anyway.
        defer { if downloaded.temporary { try? FileManager.default.removeItem(at: downloaded.file) } }

        guard let provider = CGDataProvider(url: downloaded.file as CFURL),
              let original = CGPDFDocument(provider)
        else {
            throw RenderError.malformedPage("the document's PDF does not open")
        }

        let certified = Self.isCertified(original)

        for position in 0..<original.numberOfPages {
            guard let page = original.page(at: position + 1), let dictionary = page.dictionary else { continue }
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "UserUnit", &object) {
                var unit: CGPDFReal = 0
                guard CGPDFDictionaryGetNumber(dictionary, "UserUnit", &unit), unit == 1 else {
                    throw RenderError.unsupportedFormat("non-default PDF UserUnit")
                }
            }
        }
        let resolved = try await pageOrder(
            index: index, original: original, owner: documentID, maximumPages: maximumPages
        )
        onPageCount(resolved.pages.count, resolved.documentPageCount)
        let order = resolved.pages
        let pages = try await sheets(
            order: order,
            index: index,
            original: original,
            owner: documentID,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable
        )
        let total = originalBytes + Int64(pages.count)
        onProgress(originalBytes, total)

        let marked = pages.compactMap(\.marks)
        let assets = PageAssets.decodable(
            await assets(for: marked, index: index, owner: documentID),
            channel: "annotated"
        )
        let holes = PageAssets.holes(in: marked, assets: assets)
        if holes.pages > 0 { onMissingImages(holes.pages, holes.images) }

        // Everything from here on is drawing, and drawing is the long part of
        // a render — so it goes off the caller's executor into a detached
        // task, the way `NotebookRenderer` and `PageRenderer` already do, and
        // one a cancelled caller cancels too (`RenderWork.detached`). The
        // `CGContext` and the pages of the original are made inside it:
        // neither is `Sendable`, and neither needs to cross — the original is
        // a file, and a file opens wherever the drawing happens to be.
        let source = downloaded.file
        do {
            try await RenderWork.detached {
                // The cheap way first: append the marks to the original
                // instead of redrawing it. It keeps the document's links and
                // outline, which redrawing loses — and it refuses more often
                // than not, because it only knows how to put marks onto pages
                // that are already there.
                if allowOverlay, try overlay(
                    order: order, pages: pages, original: source, certified: certified, assets: assets, to: output
                ) {
                    onProgress(total, total)
                    return
                }
                if certified {
                    guard !refuseCertified else {
                        throw RenderError.unsupportedFormat(
                            "a certified PDF (/Perms) whose certification a fresh export would drop"
                        )
                    }
                    RMRenderLog.pageError(
                        "annotated: \(documentID) is a certified PDF — drawn afresh, without its certification"
                    )
                    onCertificationDropped()
                }
                try Self.redraw(pages, original: source, assets: assets, author: author, to: output) { done in
                    onProgress(originalBytes + Int64(done), total)
                }
            }
        } catch {
            // A cancelled or failed redraw leaves a truncated PDF behind, and
            // a truncated PDF at the path the caller asked for is worse than
            // nothing: it opens, and it is wrong. The same rule
            // `PageRenderer.pdf(pages:…to:)` keeps, for the same reason.
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Whether the original carries certification permissions: a `/Perms`
    /// entry in its catalog, the mark of a document signed so that changes
    /// to it are restricted or detected.
    static func isCertified(_ document: CGPDFDocument) -> Bool {
        var permissions: CGPDFObjectRef?
        guard let catalog = document.catalog else { return false }
        return CGPDFDictionaryGetObject(catalog, "Perms", &permissions)
    }

    /// The long way round: every page drawn afresh into a new PDF, the page
    /// of the original under the marks wherever there is one.
    ///
    /// Synchronous on purpose — this is the body `renderPDF` hands to
    /// `RenderWork.detached`, and it makes its own `CGContext` and opens the
    /// original itself because neither may be carried into a detached task.
    /// `onPageDrawn` is handed the number of pages finished, once per page.
    private static func redraw(
        _ pages: [Sheet],
        original: URL,
        assets: [String: Data],
        author: String?,
        to output: URL,
        onPageDrawn: (Int) -> Void
    ) throws {
        guard let provider = CGDataProvider(url: original as CFURL),
              let document = CGPDFDocument(provider)
        else {
            throw RenderError.malformedPage("the document's PDF does not open")
        }
        guard let consumer = CGDataConsumer(url: output as CFURL) else {
            throw RenderError.pdfContextUnavailable
        }
        // The box here is a default only: every page overrides its own,
        // because one document can mix formats — see `AnnotationGeometry`.
        var mediaBox = CGRect(origin: .zero, size: pages.first?.sheet ?? PaperSize.a4.points())
        let info = PDFDocumentInfo.dictionary(author: author)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            throw RenderError.pdfContextUnavailable
        }

        let navigation = try PDFNavigation(original: original, document: document,
                                           mapping: pages.map { ($0.redir, $0.marks?.rootDocumentVisible != false, $0.sheet) })
        for (done, page) in pages.enumerated() {
            // Nothing in this loop suspends, so it is not interruptible on its
            // own: without asking, a redraw of a five-hundred-page book runs to
            // the end after the user has already dismissed it. The detached
            // task this runs in is the one `RenderWork.detached` cancels, so
            // the question is asked of the right task.
            try Task.checkCancellation()
            drawPage(
                source: originalPage(page.redir, in: document),
                marks: page.marks,
                sheet: page.sheet,
                into: context,
                assets: assets,
                navigation: { navigation.draw(page: done, in: $0) }
            )
            onPageDrawn(done + 1)
        }
        navigation.finish(in: context)
        context.closePDF()
    }

    /// The page of the original a `redir` names, or `nil` where it names
    /// none the file has.
    ///
    /// `redir` counts from zero in the protocol and from one in CoreGraphics,
    /// and the one is added only after the number is known to lie inside the
    /// file: it arrives from a `.content` anybody can write, and `Int.max + 1`
    /// is a trap, not a missing page. `pageOrder` has already dropped every
    /// such number; this is the same rule kept where the page is opened, so
    /// it does not hang on who built the list.
    static func originalPage(_ redir: Int?, in document: CGPDFDocument) -> CGPDFPage? {
        guard let redir, redir >= 0, redir < document.numberOfPages else { return nil }
        return document.page(at: redir + 1)
    }

    /// The bytes of the pages' attachments, by file name — a page added on
    /// the tablet inside an imported document can carry captures like any
    /// notebook page. Through the cache, like every small blob here.
    private func assets(
        for marks: [RMPage],
        index: DocumentFiles,
        owner: String
    ) async -> [String: Data] {
        await PageAssets.gather(for: marks, index: index, channel: "annotated") { entry in
            try await blob(entry, owner: owner)
        }
    }

    /// One page of the output: the page of the imported file underneath, the
    /// marks over it, on a sheet grown to hold whatever ran off the edges.
    ///
    /// Apart from the loop that drives it so that it can be looked at one page
    /// at a time: the box and the placement inside it are the easiest things
    /// here to get wrong, and from `renderPDF` neither is reachable without a
    /// live source of documents.
    static func drawPage(
        source: CGPDFPage?,
        marks: RMPage?,
        sheet size: CGSize,
        into context: CGContext,
        assets: [String: Data] = [:],
        navigation: ((CGContext) -> Void)? = nil
    ) {
        let sheet = CGRect(origin: .zero, size: size)
        // The drawing happens in `.rm` units: the sheet becomes a page of the
        // size the strokes were written on — which is what `PageRenderer`
        // already knows how to draw into and how to measure.
        let units = AnnotationGeometry.units(of: size)
        let bounds = marks.map {
            PageRenderer.contentBounds(of: $0, pageSize: units, edge: Self.markEdge)
        }
            ?? CGRect(origin: .zero, size: units)
        let box = AnnotationGeometry.box(bounds, on: sheet)

        let placement = source.map { sourceTransform($0, onto: sheet) }
        let crop = source.flatMap { page -> CGRect? in
            guard marks?.rootDocumentVisible != false,
                  page.getBoxRect(.cropBox) != page.getBoxRect(.mediaBox),
                  let placement else { return nil }
            return page.getBoxRect(.cropBox).applying(placement)
        }
        context.beginPDFPage(pageInfo(mediaBox: box, artBox: sheet, cropBox: crop))
        // Nothing is translated, and that is the point worth stating: a media
        // box beginning left of zero moves the page's edges, not its
        // coordinates. Drawing goes on at the same numbers throughout, and
        // marks that would fall outside the original box now fall inside the
        // grown one.
        //
        // Putting a `translateBy(-box.minX, …)` here reads plausible and is
        // wrong — checked against the tablet's export, it slides the whole
        // page right by the width of the growth. This page is drawn through a
        // function a test can reach, so that the geometry is held against a
        // measurement rather than a guess.
        // A hidden source page is the user's own edit: the tablet shows the
        // marks on a blank sheet, and so does this. The sheet keeps the
        // page's size — hiding changes what is drawn, not the geometry.
        if let source, marks?.rootDocumentVisible != false {
            context.saveGState()
            context.concatenate(sourceTransform(source, onto: sheet))
            context.drawPDFPage(source)
            context.restoreGState()
        }
        if let marks {
            context.saveGState()
            context.scaleBy(x: Calibration.pointsPerUnit, y: Calibration.pointsPerUnit)
            PageRenderer.draw(marks, in: context, pageSize: units, bounds: bounds, assets: assets)
            context.restoreGState()
        }
        navigation?(context)
        context.endPDFPage()
    }

    static func sourceTransform(_ source: CGPDFPage, onto sheet: CGRect) -> CGAffineTransform {
        let media = source.getBoxRect(.mediaBox)
        return CGAffineTransform(translationX: sheet.midX, y: sheet.midY)
            .rotated(by: -CGFloat(source.rotationAngle) * .pi / 180)
            .translatedBy(x: -media.midX, y: -media.midY)
    }

    /// The imported PDF as a file: out of the cache when it is there, from the
    /// network otherwise. `temporary` says whether the caller has to clean up
    /// after itself — a cached file must outlive the render.
    private func original(
        _ entry: DocumentFile,
        owner: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (file: URL, temporary: Bool) {
        let file = try await blobs.file(
            hash: entry.hash,
            name: entry.name,
            owner: owner,
            size: Int64(entry.size),
            onProgress: onProgress
        )
        return (file.url, file.isTemporary)
    }

    /// A small file of the document: a page, `.content`. Through the cache,
    /// so that a second render of the same document costs no network.
    private func blob(_ entry: DocumentFile, owner: String) async throws -> Data {
        try await blobs.data(hash: entry.hash, name: entry.name, owner: owner)
    }

    /// The margin along an edge grown to hold marks in the page margins.
    ///
    /// Its own number, distinct from the notebook case: the tablet adds a
    /// fixed 5 mm of air to every side the ink spills over — 14.173228 pt in
    /// its exported PDFs — where a notebook sheet hugs
    /// the ribbon (`PageRenderer.InkEdge`). Derived, not restated: the file
    /// works in sheet units, so the tablet's millimetres go through the same
    /// unit the rest of the page does.
    static let markEdge = PageRenderer.InkEdge.centreline(
        margin: 5 * 72 / 25.4 / Calibration.pointsPerUnit
    )

    /// One page on its way to the output.
    ///
    /// The page of the imported file is named rather than held: a `CGPDFPage`
    /// is not `Sendable`, and the drawing runs in a detached task (see
    /// `renderPDF`) that opens the document again from the file it came from
    /// and takes its page by this number. Nothing else about the sheet needs
    /// the handle — its size is read once, where the sheet is made.
    private struct Sheet: Sendable {
        /// The page of the imported file behind the marks, counting from zero
        /// as `redir` does; `nil` for a page added on the tablet.
        let redir: Int?
        let marks: RMPage?
        let sheet: CGSize
    }

    /// Put the marks onto the original rather than redrawing it. `false` means
    /// this document is not one the overlay can do, and the caller redraws.
    ///
    /// The refusals are deliberate and wide. The overlay writes onto pages the
    /// original already has, in the order it already has them, so anything
    /// else — a page added on the tablet, pages reordered or dropped, or
    /// encryption — goes the long way round. A document that comes out wrong
    /// is worse than one that comes out without its links.
    ///
    /// A `certified` original is refused as soon as there is something to
    /// append: an incremental update would break its certification. With
    /// nothing to append it is copied as it stands, certification and all.
    private func overlay(
        order: [PageOrder.Page],
        pages: [Sheet],
        original: URL,
        certified: Bool,
        assets: [String: Data],
        to output: URL
    ) throws -> Bool {
        guard let file = try? PDFFile(url: original) else { return false }
        guard let originalPages = try? file.pages(), originalPages.count == order.count else { return false }
        // Page *n* of the document must be page *n* of the file: that is what
        // makes writing onto the original the same document the tablet shows.
        for (position, page) in order.enumerated() where page.redir != position {
            return false
        }
        // A page whose source the user hid cannot be done by appending: the
        // original page would stay visible under the marks. The redraw path
        // knows how to leave it out. Text, images and erased strokes use a
        // native PDF Form rendered by the same PageRenderer as fresh export.
        for sheet in pages where sheet.marks?.rootDocumentVisible == false { return false }

        var overlays: [PDFOverlayWriter.Overlay] = []
        for (position, sheet) in pages.enumerated() {
            guard let marks = sheet.marks else { continue }
            guard !marks.strokes.isEmpty || !marks.highlights.isEmpty || !marks.images.isEmpty || marks.text != nil else { continue }
            let original = originalPages[position]
            guard let box = original.mediaBox, original.rotation.isMultiple(of: 90) else { return false }
            let rotated = !original.rotation.isMultiple(of: 360)
            let drawingBox = rotated ? CGRect(origin: .zero, size: sheet.sheet) : box
            let built = marks.text == nil && marks.images.isEmpty ? MarkContentStream.build(marks, mediaBox: drawingBox) : nil
            var grown = AnnotationGeometry.box(
                PageRenderer.contentBounds(
                    of: marks,
                    pageSize: AnnotationGeometry.units(of: drawingBox.size),
                    edge: Self.markEdge
                ),
                on: drawingBox
            )
            var native: Data?
            var content: Data
            if let built {
                content = built.content
            } else {
                let data = NSMutableData()
                var media = grown
                guard let consumer = CGDataConsumer(data: data),
                      let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
                    throw RenderError.pdfContextUnavailable
                }
                context.beginPDFPage(nil)
                context.translateBy(x: drawingBox.minX, y: drawingBox.minY)
                context.scaleBy(x: Calibration.pointsPerUnit, y: Calibration.pointsPerUnit)
                let units = AnnotationGeometry.units(of: drawingBox.size)
                PageRenderer.draw(marks, in: context, pageSize: units,
                                  bounds: PageRenderer.contentBounds(of: marks, pageSize: units, edge: Self.markEdge),
                                  assets: assets)
                context.endPDFPage()
                context.closePDF()
                native = data as Data
                content = Data("q /RMNative Do Q\n".utf8)
            }
            if rotated {
                // Marks use the displayed page's frame. The appended Form uses
                // the original page's frame and keeps its /Rotate unchanged.
                let placement = CGAffineTransform(translationX: drawingBox.midX, y: drawingBox.midY)
                    .rotated(by: -CGFloat(original.rotation % 360) * .pi / 180)
                    .translatedBy(x: -box.midX, y: -box.midY)
                    .inverted()
                let matrix = [placement.a, placement.b, placement.c, placement.d, placement.tx, placement.ty]
                    .map { PDFWriter.number(Double($0), places: 10) }.joined(separator: " ")
                content = Data("q \(matrix) cm\n".utf8) + content + Data("\nQ\n".utf8)
                grown = grown.applying(placement)
            }
            let unchangedBox = zip(
                [grown.minX, grown.minY, grown.maxX, grown.maxY],
                [box.minX, box.minY, box.maxX, box.maxY]
            ).allSatisfy { abs($0 - $1) < 1e-8 }
            overlays.append(
                PDFOverlayWriter.Overlay(
                    pageIndex: position,
                    content: content,
                    states: built?.states ?? [],
                    images: built?.images ?? [],
                    box: unchangedBox ? nil : grown,
                    formPDF: native
                )
            )
        }
        // A document whose pages carry no marks at all — the tablet writes an
        // empty `.rm` for a page merely opened — is its own original, and the
        // best thing to do with it is nothing. Redrawing it would re-encode
        // a hundred megabytes of scan to arrive at the same document.
        if overlays.isEmpty {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: original, to: output)
            RMRenderLog.pageDebug("annotated: no marks on any page — the original goes out as it is")
            return true
        }
        if certified {
            RMRenderLog.pageDebug("annotated: overlay declined — the original is certified")
            return false
        }

        do {
            try PDFOverlayWriter().write(
                file: file,
                pages: originalPages,
                original: original,
                overlays: overlays,
                to: output
            )
        } catch {
            RMRenderLog.pageDebug("annotated: overlay declined — \(String(describing: error))")
            return false
        }
        RMRenderLog.pageDebug("annotated: marks appended to the original, \(overlays.count) pages")
        return true
    }

    /// Where the marker went on every page, in the frame the flattened
    /// page is rasterised in; an empty list for a page with no mark.
    ///
    /// Here rather than in the caller because the sheet a marked page
    /// stands on is this renderer's own answer — the original's page where
    /// there is one, the scene the `.rm` declares where the page was added
    /// on the tablet — and a band is stated in fractions of the box grown
    /// around it. Both roads out of this renderer grow the same box, so a
    /// band does not depend on which one the flatten took.
    ///
    /// It costs what a flatten costs short of the drawing: the original is
    /// fetched, out of the cache where it is there, and the marks are
    /// parsed. Nothing is drawn and nothing is read.
    ///
    /// `maximumPages` is the cut `renderPDF` makes, so the two answer for the
    /// same pages.
    public func marks(
        documentID: String,
        index: DocumentFiles,
        maximumPages: Int? = nil
    ) async throws -> [MarkedPage] {
        guard let originalEntry = index.file(withExtension: "pdf") else {
            throw RenderError.malformedPage("an annotated document without its PDF")
        }
        let downloaded = try await original(originalEntry, owner: documentID) { _, _ in }
        defer { if downloaded.temporary { try? FileManager.default.removeItem(at: downloaded.file) } }
        guard let provider = CGDataProvider(url: downloaded.file as CFURL),
              let original = CGPDFDocument(provider)
        else {
            throw RenderError.malformedPage("the document's PDF does not open")
        }
        let order = try await pageOrder(
            index: index, original: original, owner: documentID, maximumPages: maximumPages
        ).pages
        let pages = try await sheets(order: order, index: index, original: original, owner: documentID)
        return zip(order, pages).map { entry, page in
            // The page's own name travels with its marks: an edit made to
            // them later goes to that file, and the place of the page in the
            // document is not a name — pages are added, moved and deleted.
            guard let marks = page.marks else { return MarkedPage(pageID: entry.id) }
            return MarkedPage(
                bands: PageMarks.bands(of: marks, sheet: page.sheet),
                highlights: PageMarks.highlights(of: marks, sheet: page.sheet),
                pageID: entry.id
            )
        }
    }

    private func sheets(
        order: [PageOrder.Page],
        index: DocumentFiles,
        original: CGPDFDocument,
        owner: String,
        onUnsupported: @escaping @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @escaping @Sendable (_ pages: Int) -> Void = { _ in }
    ) async throws -> [Sheet] {
        // A record per page, found once. Searching the index for every page
        // is a scan inside a loop, and a book runs to hundreds of both.
        var entryOfPage: [String: DocumentFile] = [:]
        for entry in index.files where entry.fileExtension == "rm" {
            entryOfPage[entry.fileBaseName] = entry
        }

        // Marks are fetched with a bounded fan-out — the same
        // `RenderWork.boundedConcurrentMap` the notebook walk runs on, and for
        // the same reason: one after another costs a network round trip per
        // page, and a book with marks on two hundred of them is two hundred of
        // them in a row while the caller waits. Order is restored by
        // position — the pages are assembled below in the document's order,
        // not in the order the blobs happen to land.
        var marks: [RMPage?] = Array(repeating: nil, count: order.count)
        let jobs: [(position: Int, entry: DocumentFile)] = order.enumerated().compactMap { position, page in
            entryOfPage[page.id].map { (position, $0) }
        }
        // The generations of the marks we could not read. The original page
        // still goes out under them, so the loss is invisible on the sheet —
        // which is exactly why it has to be visible somewhere else.
        var oldVersions: [Int] = []
        // Marks that could not be read for any other reason. The original PDF
        // still goes out, so the loss is invisible on the page: the document
        // opens and simply has none of the user's ink on it.
        var unreadable = 0
        let parsed = try await RenderWork.boundedConcurrentMap(
            jobs
        ) { [self] job -> (page: RMPage?, version: Int?, unreadable: Bool) in
            let data = try await blob(job.entry, owner: owner)
            // One unreadable page must not cost the whole document:
            // the original still goes out, only without its marks.
            do {
                return (try await parse(data), nil, false)
            } catch ParseError.unsupportedVersion(let version) {
                return (nil, version, false)
            } catch {
                RMRenderLog.pageError(
                    """
                    annotated: marks on page \(job.position) not parsed: \
                    \(String(describing: error))
                    """
                )
                return (nil, nil, true)
            }
        }
        for (job, result) in zip(jobs, parsed) {
            marks[job.position] = result.page
            if let version = result.version { oldVersions.append(version) }
            if result.unreadable { unreadable += 1 }
        }

        var sheets: [Sheet] = []
        for (position, page) in order.enumerated() {
            let source = Self.originalPage(page.redir, in: original)
            // The sheet is the original page wherever there is one. Otherwise
            // it is the scene of the `.rm` — the panel the page was made on —
            // in points.
            let sheet: CGSize
            if let source {
                let box = source.getBoxRect(.mediaBox)
                sheet = source.rotationAngle.isMultiple(of: 180)
                    ? box.size : CGSize(width: box.height, height: box.width)
            } else {
                sheet = AnnotationGeometry.sheet(
                    forScene: PageRenderer.plausibleCanvas(marks[position]?.paperSize) ?? PageRenderer.defaultPageSize
                )
            }
            sheets.append(Sheet(redir: page.redir, marks: marks[position], sheet: sheet))
        }

        // What the parser could not read is said out loud. There are no
        // ordinary reasons left in this number: the scene tree, the text and
        // the attachments are all read and count themselves only when their
        // own parse fails, so anything above zero is a piece of the page that
        // did not survive. It stands on its own — grouped with the skipped
        // count, it would vanish without a word — and it is an error
        // rather than a debug line for the same reason: a loss nobody is told
        // about is the one that ships.
        let skipped = sheets.compactMap(\.marks).reduce(0) { $0 + $1.skippedBlocks }
        if skipped > 0 {
            RMRenderLog.pageError(
                """
                annotated: \(skipped) blocks across \
                \(sheets.count) pages could not be read
                """
            )
        }

        if !oldVersions.isEmpty {
            RMRenderLog.pageError(
                """
                annotated: \(owner) carries marks on \
                \(oldVersions.count) pages in an older .rm format \
                (versions \(Set(oldVersions).sorted().map(String.init).joined(separator: ", "))) \
                — the pages go out without them
                """
            )
            onUnsupported(oldVersions.count)
        }

        if unreadable > 0 {
            RMRenderLog.pageError(
                """
                annotated: \(owner) carries marks on \
                \(unreadable) pages that could not be read at all \
                — the pages go out without them
                """
            )
            onUnreadable(unreadable)
        }
        return sheets
    }

    /// The pages of the document, in order, each with the page of the
    /// imported file it belongs to.
    ///
    /// When `.content` cannot be read there is still something sensible to
    /// do: hand back the imported file page for page. The marks are lost, the
    /// document is not — and the log says which happened.
    ///
    /// Every `redir` is checked against the original here, once: one the
    /// file has no page for stands on none. The cut comes last, over the
    /// list everything else has settled, and `documentPageCount` is the
    /// length of that list before it.
    private func pageOrder(
        index: DocumentFiles,
        original: CGPDFDocument,
        owner: String,
        maximumPages: Int? = nil
    ) async throws -> (pages: [PageOrder.Page], documentPageCount: Int) {
        // A negative count from CoreGraphics is not something it answers, but
        // a range built on one is a trap, and the answer costs nothing to pin.
        let originalPages = max(original.numberOfPages, 0)
        let pages: [PageOrder.Page]
        if let entry = index.file(withExtension: "content"),
           let data = try? await blob(entry, owner: owner),
           let layout = try? PageOrder.layout(from: data),
           !layout.pages.isEmpty {
            pages = PageOrder.checked(layout.pages, originalPages: originalPages)
            // Every refusal counted, wherever it was made: a number past the
            // original here, and one below zero or not a number at all where
            // `.content` was read.
            let refused = pages.count(where: \.refusedRedir)
            if refused > 0 {
                RMRenderLog.pageError(
                    """
                    annotated: \(owner) names \(refused) pages of the original it does not have \
                    (of \(originalPages)) — they are drawn on blank paper
                    """
                )
            }
        } else {
            RMRenderLog.pageError("annotated: .content unreadable — the marks are dropped")
            pages = (0..<originalPages).map { PageOrder.Page(id: "", template: nil, redir: $0) }
        }
        guard let maximumPages, pages.count > max(maximumPages, 1) else { return (pages, pages.count) }
        return (Array(pages.prefix(max(maximumPages, 1))), pages.count)
    }

    private func parse(_ data: Data) async throws -> RMPage {
        try await RenderWork.detached { try RMParser.parsePage(data) }
    }

    /// The same trick as in `PageRenderer`: a page's own box travels as the
    /// bytes of a `CGRect`, or CoreGraphics ignores it.
    ///
    /// The art box is the page as it was imported, and it is there for the
    /// same reason the tablet's own export writes one: once the media box has
    /// grown around the marks, nothing else in the file says where the sheet
    /// originally stood.
    private static func pageInfo(mediaBox: CGRect, artBox: CGRect, cropBox: CGRect? = nil) -> CFDictionary {
        func data(_ rectangle: CGRect) -> CFData {
            var box = rectangle
            return Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        }
        var info = [
            kCGPDFContextMediaBox as String: data(mediaBox),
            kCGPDFContextArtBox as String: data(artBox),
        ]
        if let cropBox { info[kCGPDFContextCropBox as String] = data(cropBox) }
        return info as CFDictionary
    }
}
