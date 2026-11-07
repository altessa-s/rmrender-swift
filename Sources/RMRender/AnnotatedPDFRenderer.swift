// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks
import RMLines
import Synchronization

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
    /// How many pages of the document one run of native Forms spans
    /// (`overlayUnits`): `Self.nativeRunPages`, unless a test asks for
    /// another — one, to draw every native Form alone, as a PDF of its own.
    private let nativeRunPages: Int

    public init(blobs: any PageBlobs) {
        self.init(blobs: blobs, nativeRunPages: Self.nativeRunPages)
    }

    init(blobs: any PageBlobs, nativeRunPages: Int) {
        self.blobs = blobs
        self.nativeRunPages = max(nativeRunPages, 1)
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
    ///
    /// Marks whose bytes would not arrive — `PageBlobs` failing with anything
    /// but a cancellation — cost their own page and no more: it goes out as
    /// a page whose marks did not parse does, the original's page without
    /// them, and `onUnfetched` is called once, after the drawing, with the
    /// number of such pages. Not counted in `onUnreadable`: see
    /// `NotebookRenderer.renderPDF` for why the two are told apart. What
    /// makes the whole document impossible — the original missing or not
    /// opening, the output not writable — still throws, and so does a
    /// cancelled render.
    ///
    /// That is `.blank` of `unfetchedPages`. By default (`.placeholder`)
    /// such a page goes out as the original's page with "Rendering error"
    /// over the middle of it — written into the overlay as a native Form
    /// where the overlay is taken, drawn onto the page where the document is
    /// redrawn — and a page added on the tablet as a plain sheet with the
    /// same label; `onUnfetched` is told either way. `.strict` fails the
    /// render with `PageFetchError`, naming the page, and leaves no output.
    /// Marks that arrived and would not parse go out as they always did.
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
        unfetchedPages: UnfetchedPagePolicy = .placeholder,
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
        // Called at most once, after the drawing: see above.
        onUnfetched: @escaping @Sendable (_ pages: Int) -> Void = { _ in },
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
        // Measured, not kept: every page's marks are parsed here for what the
        // drawing has to know before it starts — the sheet, whether there is
        // anything to draw, which attachments to fetch — and let go. They are
        // parsed again when their page is drawn (`marks(of:at:owner:)`).
        // Kept, every page's marks stood parsed for the length of the render
        // — about a quarter of a megabyte for a page marked all over, and a
        // book has thousands of pages.
        let (pages, unfetched) = try await sheets(
            order: order,
            index: index,
            original: original,
            owner: documentID,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable,
            unfetchedPages: unfetchedPages,
            keep: MarkSummary.init
        )
        let total = originalBytes + Int64(pages.count)
        onProgress(originalBytes, total)

        let marked = pages.compactMap(\.marks)
        let images = PageAssets.decoded(
            await assets(Set(marked.flatMap(\.imageFiles)), index: index, owner: documentID),
            channel: "annotated"
        )
        let holes = PageAssets.holes(in: marked.map(\.imageFiles), available: Set(images.keys))
        if holes.pages > 0 { onMissingImages(holes.pages, holes.images) }

        // Everything from here on is drawing, and drawing is the long part of
        // a render — so it goes off the caller's executor into a detached
        // task, the way `NotebookRenderer` and `PageRenderer` already do, and
        // one a cancelled caller cancels too (`RenderWork.detachedWaiting`).
        // The `CGContext` and the pages of the original are made inside it:
        // neither is `Sendable`, and neither needs to cross — the original is
        // a file, and a file opens wherever the drawing happens to be.
        let source = downloaded.file
        // The pages whose marks arrived for the measuring and not for the
        // drawing — a cache emptied in between, a connection dropped.
        let missed = PageLedger()
        let marks: @Sendable (Int) async throws -> RMPage? = { [self] position in
            try await self.marks(
                of: pages[position], at: position, owner: documentID, missed: missed, unfetchedPages: unfetchedPages
            )
        }
        // The pages drawn with the label: those whose marks did not arrive
        // for the measuring, and — found as the drawing comes to them —
        // those whose marks did not arrive for the drawing.
        let placeholders = unfetchedPages == .placeholder ? unfetched : []
        do {
            try await RenderWork.detachedWaiting {
                // The cheap way first: append the marks to the original
                // instead of redrawing it. It keeps the document's links and
                // outline, which redrawing loses — and it refuses more often
                // than not, because it only knows how to put marks onto pages
                // that are already there.
                if allowOverlay, try await overlay(
                    order: order, pages: pages, original: source, certified: certified, images: images,
                    placeholders: placeholders, missedArePlaceholders: unfetchedPages == .placeholder,
                    to: output, marks: marks
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
                // An overlay that declined part of the way through may have
                // missed pages the redraw now fetches afresh: what counts is
                // what the document that goes out lacks.
                missed.clear()
                try await Self.redraw(
                    pages, original: source, images: images, author: author,
                    placeholders: placeholders, missedArePlaceholders: unfetchedPages == .placeholder,
                    to: output, marks: marks
                ) { done in
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
        let lost = unfetched.union(missed.positions)
        if !lost.isEmpty {
            RMRenderLog.pageError(
                """
                annotated: \(documentID) carries marks on \(lost.count) pages \
                whose bytes did not arrive — the pages go out without them\
                \(unfetchedPages == .placeholder ? ", labelled" : "")
                """
            )
            onUnfetched(lost.count)
        }
    }

    /// Positions of pages, gathered from the tasks a drawing runs in.
    private final class PageLedger: Sendable {
        private let held = Mutex<Set<Int>>([])

        var positions: Set<Int> { held.withLock { $0 } }

        func insert(_ position: Int) {
            _ = held.withLock { $0.insert(position) }
        }

        func clear() {
            held.withLock { $0.removeAll() }
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
    /// Run inside the task `renderPDF` hands to `RenderWork.detachedWaiting`,
    /// and it makes its own `CGContext` and opens the original itself because
    /// neither may be carried into a detached task. The marks of a page are
    /// asked of `marks` when the page comes up — a few pages ahead, so the
    /// parsing goes on beside the drawing — and let go once it is drawn.
    /// `onPageDrawn` is handed the number of pages finished, once per page.
    ///
    /// The pages of `placeholders`, and with `missedArePlaceholders` those
    /// whose marks do not arrive now, are drawn with the label of
    /// `UnfetchedPlaceholder` over them.
    private static func redraw(
        _ pages: [Sheet<MarkSummary>],
        original: URL,
        images: [String: CGImage],
        author: String?,
        placeholders: Set<Int>,
        missedArePlaceholders: Bool,
        to output: URL,
        marks: @escaping @Sendable (Int) async throws -> RMPage?,
        onPageDrawn: (Int) -> Void
    ) async throws {
        guard let provider = CGDataProvider(url: original as CFURL),
              let document = CGPDFDocument(provider)
        else {
            throw RenderError.malformedPage("the document's PDF does not open")
        }
        let sink = try PDFSink(url: output)
        // The box here is a default only: every page overrides its own,
        // because one document can mix formats — see `AnnotationGeometry`.
        var mediaBox = CGRect(origin: .zero, size: pages.first?.sheet ?? PaperSize.a4.points())
        let info = PDFDocumentInfo.dictionary(author: author)
        guard let consumer = sink.consumer(), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else {
            throw RenderError.pdfContextUnavailable
        }

        let navigation = try PDFNavigation(original: original, document: document,
                                           mapping: pages.map { ($0.redir, $0.marks?.rootDocumentVisible != false, $0.sheet) })
        let drawing = PageRenderer.PageImages(decoded: images)
        // The ink of a page is written where its marks are parsed, beside the
        // drawing, and appended once the document is closed — see
        // `PageRenderer.PDFPages`, which does the same for a notebook.
        let update = InkUpdate()
        try await RenderWork.boundedConcurrentForEach(
            Array(pages.indices), limit: RenderWork.inkConcurrency
        ) { position -> (marks: PreparedMarks?, placeholder: Bool) in
            // A page with no marks has nothing to fetch; one whose marks did
            // not arrive comes back as `nil` too, and is drawn without them
            // — or with the label over it.
            guard pages[position].marks != nil else { return (nil, placeholders.contains(position)) }
            guard let marks = try await marks(position) else { return (nil, missedArePlaceholders) }
            return (PreparedMarks(marks, sheet: pages[position].sheet), false)
        } consume: { done, drawn in
            // The drawing itself does not suspend, so it is not interruptible
            // on its own: without asking, a redraw of a five-hundred-page book
            // runs to the end after the user has already dismissed it. The
            // detached task this runs in is the one `RenderWork` cancels, so
            // the question is asked of the right task.
            try Task.checkCancellation()
            let page = pages[done]
            let prepared = drawn.marks
            drawPage(
                source: originalPage(page.redir, in: document),
                marks: prepared?.marks,
                sheet: page.sheet,
                into: context,
                images: drawing,
                navigation: { navigation.draw(page: done, in: $0) },
                inkSplit: prepared?.split,
                masks: update.masks,
                placeholder: drawn.placeholder
            )
            if let ink = prepared?.ink { try update.append(ink, page: done) }
            onPageDrawn(done + 1)
        }
        navigation.finish(in: context)
        context.closePDF()
        try update.finish(into: sink)
        try sink.close()
    }

    /// A page's marks with their ink written, ready for `drawPage` to draw
    /// the rest: the ink of a redrawn page is written apart, beside the
    /// drawing, as a notebook's is (`PageRenderer.PDFPages`).
    private struct PreparedMarks: Sendable {
        let marks: RMPage
        /// Where CoreGraphics' strokes end and the written ink begins.
        let split: Int
        let ink: PreparedInk?

        /// The marks on a sheet of `size`, under the transform `drawPage`
        /// draws them under.
        init(_ marks: RMPage, sheet size: CGSize) {
            let units = AnnotationGeometry.units(of: size)
            let geometry = marks.text.map { TextGeometry($0, pageSize: units) }
            let written = PageRenderer.writtenInk(of: marks, pageSize: units, geometry: geometry) {
                $0.scaleBy(x: Calibration.pointsPerUnit, y: Calibration.pointsPerUnit)
            }
            self.marks = marks
            split = written.split
            ink = written.ink
        }
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
        _ wanted: Set<String>,
        index: DocumentFiles,
        owner: String
    ) async -> [String: Data] {
        await PageAssets.gather(wanted, index: index, channel: "annotated") { entry in
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
    ///
    /// `inkSplit` and `masks` are `PageRenderer.draw`'s: the redraw writes a
    /// page's ink apart and draws the rest here. `placeholder` puts the
    /// label of a page whose marks did not arrive over the middle of the
    /// sheet (`UnfetchedPlaceholder`).
    static func drawPage(
        source: CGPDFPage?,
        marks: RMPage?,
        sheet size: CGSize,
        into context: CGContext,
        images: PageRenderer.PageImages = PageRenderer.PageImages(),
        navigation: ((CGContext) -> Void)? = nil,
        inkSplit: Int? = nil,
        masks: InkMaskLedger? = nil,
        placeholder: Bool = false
    ) {
        let sheet = CGRect(origin: .zero, size: size)
        // The drawing happens in `.rm` units: the sheet becomes a page of the
        // size the strokes were written on — which is what `PageRenderer`
        // already knows how to draw into and how to measure.
        let units = AnnotationGeometry.units(of: size)
        // The typed text laid out once, for the measuring and the drawing.
        let geometry = marks?.text.map { TextGeometry($0, pageSize: units) }
        let bounds = marks.map {
            PageRenderer.contentBounds(of: $0, pageSize: units, edge: Self.markEdge, geometry: geometry)
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
            PageRenderer.draw(
                marks, in: context, pageSize: units, bounds: bounds, images: images, geometry: geometry,
                inkSplit: inkSplit, masks: masks
            )
            context.restoreGState()
        }
        if placeholder { UnfetchedPlaceholder.draw(on: sheet, in: context) }
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
    ///
    /// `Marks` is what is kept of the page's marks: the marks themselves for
    /// a caller that reads them all (`marks(documentID:…)`), a `MarkSummary`
    /// for a render, which parses them again when it draws the page.
    private struct Sheet<Marks: Sendable>: Sendable {
        /// The page of the imported file behind the marks, counting from zero
        /// as `redir` does; `nil` for a page added on the tablet.
        let redir: Int?
        /// The page's own file, where `.content` names one the index has.
        let entry: DocumentFile?
        /// `nil` where the page carries no marks that could be read.
        let marks: Marks?
        let sheet: CGSize
    }

    /// What a render has to know of a page's marks before it draws a page:
    /// whether they hide the original, whether there is anything to write at
    /// all, and which attachments they show.
    private struct MarkSummary: Sendable {
        let rootDocumentVisible: Bool
        /// Strokes, a highlight, an image or typed text — a page the tablet
        /// merely opened carries an empty `.rm` and nothing to write.
        let hasContent: Bool
        let imageFiles: [String]
        /// Whether they set any typed text: what decides which pages share a
        /// native drawing (`overlayUnits`). A text block of nothing but
        /// blank lines — the tablet writes one on pages nobody typed on —
        /// sets no letter, embeds no face, and does not count.
        let setsType: Bool

        init(_ marks: RMPage) {
            rootDocumentVisible = marks.rootDocumentVisible
            hasContent = !marks.strokes.isEmpty || !marks.highlights.isEmpty || !marks.images.isEmpty
                || marks.text != nil
            imageFiles = marks.images.map(\.file)
            setsType = marks.text?.lines.contains { $0.contains { !$0.isWhitespace } } ?? false
        }
    }

    /// The marks of a page, parsed again for the drawing: the render measured
    /// them once (`sheets`) and kept no more than a `MarkSummary`. The same
    /// bytes parse the same way, so a page whose marks were read then are
    /// read now; bytes that are no longer what they were fail the render
    /// rather than quietly losing the ink.
    ///
    /// Bytes that do not arrive at all — a cache emptied since the measuring,
    /// a connection dropped — are the page's loss and no more: `nil`, with
    /// the page put down in `missed` for the tally `renderPDF` reports —
    /// unless `unfetchedPages` is `.strict`, when they are the render's
    /// `PageFetchError`.
    private func marks(
        of sheet: Sheet<MarkSummary>, at position: Int, owner: String, missed: PageLedger,
        unfetchedPages: UnfetchedPagePolicy
    ) async throws -> RMPage? {
        guard sheet.marks != nil, let entry = sheet.entry else {
            throw RenderError.malformedPage("page \(position) was measured without marks")
        }
        let data: Data
        do {
            data = try await blob(entry, owner: owner)
        } catch let error where !RenderWork.isCancellation(error) {
            RMRenderLog.pageError(
                "annotated: marks on page \(position) did not arrive to be drawn: \(String(describing: error))"
            )
            if unfetchedPages == .strict {
                throw PageFetchError(page: position, pageID: entry.fileBaseName, underlying: error)
            }
            missed.insert(position)
            return nil
        }
        do {
            return try await parse(data)
        } catch {
            throw RenderError.malformedPage(
                "the marks on page \(position) parsed when measured and not when drawn: \(String(describing: error))"
            )
        }
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
    ///
    /// The pages of `placeholders` are written as well — the label as the
    /// page's native Form, over the original — and so, with
    /// `missedArePlaceholders`, is a page whose marks do not arrive now.
    private func overlay(
        order: [PageOrder.Page],
        pages: [Sheet<MarkSummary>],
        original: URL,
        certified: Bool,
        images: [String: CGImage],
        placeholders: Set<Int>,
        missedArePlaceholders: Bool,
        to output: URL,
        marks: @escaping @Sendable (Int) async throws -> RMPage?
    ) async throws -> Bool {
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

        // Which pages carry marks, and whether each of them is one the overlay
        // can write onto — decided before a page is drawn, so that a refusal
        // costs nothing and the drawing below can go straight to the file.
        var marked: [Int] = []
        for (position, sheet) in pages.enumerated() {
            guard sheet.marks?.hasContent == true || placeholders.contains(position) else { continue }
            let original = originalPages[position]
            guard original.mediaBox != nil, original.rotation.isMultiple(of: 90) else { return false }
            marked.append(position)
        }
        // A document whose pages carry no marks at all — the tablet writes an
        // empty `.rm` for a page merely opened — is its own original, and the
        // best thing to do with it is nothing. Redrawing it would re-encode
        // a hundred megabytes of scan to arrive at the same document.
        if marked.isEmpty {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: original, to: output)
            RMRenderLog.pageDebug("annotated: no marks on any page — the original goes out as it is")
            return true
        }
        if certified {
            RMRenderLog.pageDebug("annotated: overlay declined — the original is certified")
            return false
        }

        // Each page's marks are parsed a few pages ahead of the writer, drawn
        // and deflated there, then written out in page order and gone:
        // collected first, a fully marked book held every page's marks and
        // operators — and a PDF of every page carrying text or a picture — at
        // once, which is what an extension is killed for. The drawing and the
        // deflating are most of the time and need nothing of the update, so
        // the units in the window do them side by side, each into a context
        // of its own (`PDFOverlayWriter.writeConcurrently`); the file is the
        // one the same units made one after another give. A failure of the
        // drawing itself, or of fetching what it draws, is not the overlay
        // declining, and it is carried past the fallback below as what it is.
        //
        // A unit is a page, or a run of pages whose marks are drawn as native
        // Forms (`overlayUnits`): a run is drawn into one PDF, a page after
        // another, so that the typefaces it sets are embedded once a run
        // rather than once a page (`NativeBatch`). The rest go a page at a
        // time, as they always did.
        struct DrawingFailed: Error { let underlying: any Error }
        let drawing = PageRenderer.PageImages(decoded: images)
        let sheets = pages.map(\.sheet)
        let units = Self.overlayUnits(marked, runPages: nativeRunPages) { position in
            placeholders.contains(position) || pages[position].marks?.setsType == true
        }
        do {
            try await PDFOverlayWriter().writeConcurrently(
                file: file, pages: originalPages, original: original, units: units, to: output
            ) { unit in
                do {
                    // A page alone is drawn as it always was, into a PDF of
                    // its own held in memory: only a run has a document to
                    // share.
                    let batch = unit.count > 1 ? NativeBatch() : nil
                    var overlays: [PDFOverlayWriter.Overlay] = []
                    var drawingPages: [Int?] = []
                    for position in unit {
                        // Marks that did not arrive leave the page as the
                        // original has it: an overlay that draws nothing,
                        // since the page was promised one before its marks
                        // were asked for — or, under `.placeholder`, the label.
                        let fetched = placeholders.contains(position) ? nil : try await marks(position)
                        let placeholder = placeholders.contains(position) || (fetched == nil && missedArePlaceholders)
                        let pageMarks = fetched ?? RMPage(strokes: [], skippedBlocks: 0)
                        // The drawing does not suspend, and a book is minutes
                        // of it: the question is asked once a page, as the
                        // redraw asks it.
                        try Task.checkCancellation()
                        let made = try Self.overlay(
                            pageMarks, sheet: sheets[position], on: originalPages[position], at: position,
                            images: drawing, placeholder: placeholder, batch: batch
                        )
                        overlays.append(made.overlay)
                        drawingPages.append(made.drawingPage)
                    }
                    return PDFOverlayWriter.OverlayBatch(
                        overlays: overlays, drawingPages: drawingPages, drawing: try batch?.finish()
                    )
                } catch {
                    throw DrawingFailed(underlying: error)
                }
            }
        } catch let failure as DrawingFailed {
            throw failure.underlying
        } catch is CancellationError {
            // A cancelled render is not an overlay that declined: falling back
            // to the redraw would start the whole book again for nobody.
            throw CancellationError()
        } catch {
            // At error level: the document still goes out, drawn afresh, but
            // without its links and outline — a loss with a reason that has
            // to be findable.
            RMRenderLog.pageError("annotated: overlay declined — \(String(describing: error))")
            return false
        }
        RMRenderLog.pageDebug("annotated: marks appended to the original, \(marked.count) pages")
        return true
    }

    /// The marks of one page as the overlay writes them, in the frame of the
    /// original's page; `overlay(order:…)` has already seen that the page has
    /// marks, a media box, and a rotation by a right angle.
    ///
    /// A `placeholder` is the label of a page whose marks did not arrive,
    /// written as the page's native Form: it is text, which the overlay's
    /// own operators do not set.
    ///
    /// The native Form is drawn as a page of `batch`'s PDF, shared with the
    /// other pages of the run, and `drawingPage` says which; a page without a
    /// batch, or one the batch refuses (`NativeBatch.page`), carries a PDF of
    /// its own, as `formPDF`.
    private static func overlay(
        _ marks: RMPage,
        sheet: CGSize,
        on original: PDFFile.Page,
        at position: Int,
        images: PageRenderer.PageImages,
        placeholder: Bool = false,
        batch: NativeBatch?
    ) throws -> (overlay: PDFOverlayWriter.Overlay, drawingPage: Int?) {
        guard let box = original.mediaBox else {
            throw PDFReadError.malformed("an overlay for page \(position), which has no box")
        }
        let rotated = !original.rotation.isMultiple(of: 360)
        let drawingBox = rotated ? CGRect(origin: .zero, size: sheet) : box
        let built = !placeholder && marks.text == nil && marks.images.isEmpty
            ? MarkContentStream.build(marks, mediaBox: drawingBox) : nil
        // Measured once, for the box and for the drawing alike, with the typed
        // text laid out once for both.
        let units = AnnotationGeometry.units(of: drawingBox.size)
        let geometry = marks.text.map { TextGeometry($0, pageSize: units) }
        let bounds = PageRenderer.contentBounds(of: marks, pageSize: units, edge: Self.markEdge, geometry: geometry)
        var grown = AnnotationGeometry.box(bounds, on: drawingBox)
        var native: Data?
        var drawingPage: Int?
        var content: Data
        if let built {
            content = built.content
        } else if placeholder {
            drawingPage = try batch?.page(mediaBox: grown, ink: nil) { context, _ in
                UnfetchedPlaceholder.draw(on: drawingBox, in: context)
            }
            if drawingPage == nil { native = try UnfetchedPlaceholder.form(drawingBox: drawingBox, mediaBox: grown) }
            content = Data("q /RMNative Do Q\n".utf8)
        } else {
            if let batch {
                drawingPage = try Self.nativeMarks(
                    marks, drawingBox: drawingBox, mediaBox: grown, units: units, bounds: bounds, geometry: geometry,
                    images: images, into: batch
                )
                if drawingPage == nil {
                    RMRenderLog.pageDebug("annotated: page \(position) drawn alone — a mask it shares would change size")
                }
            }
            if drawingPage == nil {
                native = try Self.nativeMarks(
                    marks, drawingBox: drawingBox, mediaBox: grown, units: units, bounds: bounds, geometry: geometry,
                    images: images
                )
            }
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
        let overlay = PDFOverlayWriter.Overlay(
            pageIndex: position,
            content: content,
            states: built?.states ?? [],
            images: built?.images ?? [],
            box: unchangedBox ? nil : grown,
            formPDF: native
        )
        return (overlay, drawingPage)
    }

    /// How many pages of the document one run of native Forms spans
    /// (`overlayUnits`).
    ///
    /// Each run embeds every face it sets once, cut to the letters of its
    /// pages, so a longer run writes fewer copies of each face — and draws
    /// its pages one after another, in one context, so it is also the unit
    /// the drawing is shared out across cores in, and what a unit in flight
    /// holds. Measured over a book of a thousand pages of typed text, each
    /// page in letters of its own: a page at a time it carried 5,623 font
    /// programs, 35 MB of a 69 MB file; in runs of 8, 7.6 MB of 38 MB; of
    /// 16, 3.7 of 33; of 32, 1.6 of 31; of 64, 0.7 of 30 — and every length
    /// from 8 up wrote it in half the time a page at a time took. Past 32
    /// the file barely shrinks while each run in flight holds twice the
    /// pages, and a short book has too few runs to keep the cores busy.
    static let nativeRunPages = 32

    /// The pages of `marked`, in order, cut into the units the overlay is
    /// made in: a page alone, or a run whose native Forms are drawn into one
    /// PDF (`NativeBatch`).
    ///
    /// Only pages that set type — `setsType`: typed text, or the label of a
    /// page whose marks did not arrive — begin and end a run, because a
    /// typeface is the one thing a run shares that the update did not
    /// already write once. A page drawn natively for anything else — a
    /// picture, an eraser, an empty text block — gains nothing from a run
    /// and would cost one: a run holds its pages until the last of them is
    /// drawn, and a book of five hundred pages of dense handwriting, each
    /// with an empty text block, drawn in runs of 32 held four times the
    /// memory it held a page at a time, for the same file to the byte.
    ///
    /// The document is cut into windows of `runPages`, by page index, so
    /// that where a run begins depends on nothing but the page numbers and
    /// which pages set type: the same document is cut the same way every
    /// time. In a window with such pages, the pages from its first to its
    /// last are one run, the pages between them carried along so that the
    /// run stays in page order; the pages outside that span, and every page
    /// of a window without type, are units of their own — so a book without
    /// typed text is made a page at a time, exactly as it was. `marked` is
    /// in ascending order.
    static func overlayUnits(
        _ marked: [Int], runPages: Int = nativeRunPages, setsType: (Int) -> Bool
    ) -> [[Int]] {
        let runPages = max(runPages, 1)
        var units: [[Int]] = []
        var start = marked.startIndex
        while start < marked.endIndex {
            let window = marked[start] / runPages
            var end = start
            while end < marked.endIndex, marked[end] / runPages == window { end += 1 }
            let pages = marked[start..<end]
            if let first = pages.firstIndex(where: setsType), let last = pages.lastIndex(where: setsType) {
                units += pages[..<first].map { [$0] }
                units.append(Array(pages[first...last]))
                units += pages[(last + 1)...].map { [$0] }
            } else {
                units += pages.map { [$0] }
            }
            start = end
        }
        return units
    }

    /// The marks of an overlay page as a PDF of one page, `mediaBox` its
    /// box, drawn in the frame of `drawingBox` — what the overlay imports as
    /// its native Form where its own operators cannot say what the marks
    /// hold (typed text, pictures).
    ///
    /// CoreGraphics draws the text and the pictures, and the ink after the
    /// last of them is written apart and appended (`InkStream`), as on a
    /// page of a redraw or a notebook; `writesInk` off leaves it all to
    /// CoreGraphics, the drawing the written ink is held against.
    static func nativeMarks(
        _ marks: RMPage,
        drawingBox: CGRect,
        mediaBox: CGRect,
        units: CGSize,
        bounds: CGRect,
        geometry: TextGeometry?,
        images: PageRenderer.PageImages,
        writesInk: Bool = true
    ) throws -> Data {
        let place = nativePlacement(drawingBox)
        let ink = writesInk
            ? PageRenderer.writtenInk(of: marks, pageSize: units, geometry: geometry, place: place)
            : (split: Int.max, ink: nil)
        guard let data = CFDataCreateMutable(nil, 0) else { throw RenderError.pdfContextUnavailable }
        let sink = PDFSink(data: data)
        let update = InkUpdate()
        var media = mediaBox
        guard let consumer = sink.consumer(),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw RenderError.pdfContextUnavailable
        }
        context.beginPDFPage(nil)
        place(context)
        PageRenderer.draw(
            marks, in: context, pageSize: units, bounds: bounds, images: images, geometry: geometry,
            inkSplit: ink.split, masks: writesInk ? update.masks : nil
        )
        context.endPDFPage()
        context.closePDF()
        if let written = ink.ink { try update.append(written, page: 0) }
        try update.finish(into: sink)
        return data as Data
    }

    /// The same drawing as a page of `batch`'s PDF: the page's number in
    /// it, or `nil` where the batch refuses the page and it has to be drawn
    /// alone (`NativeBatch.page`).
    static func nativeMarks(
        _ marks: RMPage,
        drawingBox: CGRect,
        mediaBox: CGRect,
        units: CGSize,
        bounds: CGRect,
        geometry: TextGeometry?,
        images: PageRenderer.PageImages,
        into batch: NativeBatch
    ) throws -> Int? {
        let place = nativePlacement(drawingBox)
        let ink = PageRenderer.writtenInk(of: marks, pageSize: units, geometry: geometry, place: place)
        return try batch.page(mediaBox: mediaBox, ink: ink.ink) { context, masks in
            place(context)
            PageRenderer.draw(
                marks, in: context, pageSize: units, bounds: bounds, images: images, geometry: geometry,
                inkSplit: ink.split, masks: masks
            )
        }
    }

    /// Where the marks of a native Form stand on its page: the frame of
    /// `drawingBox`, in `.rm` units.
    private static func nativePlacement(_ drawingBox: CGRect) -> (CGContext) -> Void {
        { context in
            context.translateBy(x: drawingBox.minX, y: drawingBox.minY)
            context.scaleBy(x: Calibration.pointsPerUnit, y: Calibration.pointsPerUnit)
        }
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
        // Strict: an answer of where the marks are must not take marks that
        // did not arrive for marks that are not there.
        let pages = try await sheets(order: order, index: index, original: original, owner: documentID) { $0 }.sheets
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

    /// The pages in order, each with its sheet and what `keep` keeps of its
    /// marks. `keep` runs where the marks are parsed, beside the fetch, so
    /// that what it does not keep is let go there rather than held until
    /// every page has been read.
    ///
    /// `unfetchedPages` other than `.strict` makes marks whose bytes do not
    /// arrive the loss of their own page — no marks, as for marks that do
    /// not parse — and answers their positions as `unfetched`; `.strict`
    /// turns the first such failure into the call's `PageFetchError`, and
    /// without a policy it is the whole call's as it stands, as it always
    /// was.
    private func sheets<Marks: Sendable>(
        order: [PageOrder.Page],
        index: DocumentFiles,
        original: CGPDFDocument,
        owner: String,
        onUnsupported: @escaping @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @escaping @Sendable (_ pages: Int) -> Void = { _ in },
        unfetchedPages: UnfetchedPagePolicy? = nil,
        keep: @escaping @Sendable (RMPage) -> Marks
    ) async throws -> (sheets: [Sheet<Marks>], unfetched: Set<Int>) {
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
        // What the sheet needs of the marks travels beside what is kept of
        // them: the scene's size, for a page with no original behind it, and
        // the blocks that did not read.
        typealias Measured = (kept: Marks, paperSize: CGSize?, skippedBlocks: Int)
        var marks: [Measured?] = Array(repeating: nil, count: order.count)
        let jobs: [(position: Int, entry: DocumentFile)] = order.enumerated().compactMap { position, page in
            entryOfPage[page.id].map { (position, $0) }
        }
        let losesUnfetchedPages = unfetchedPages != nil
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
        ) { [self] job -> (page: Measured?, loss: RenderWork.PageLoss?) in
            // Marks that do not arrive go the way of marks that do not parse,
            // where the caller allows it: the fan-out ends at the first error,
            // and a book is not to be lost to one dropped request. A cancelled
            // render is the one failure that is not a page's.
            let data: Data
            do {
                data = try await blob(job.entry, owner: owner)
            } catch let error where losesUnfetchedPages && !RenderWork.isCancellation(error) {
                RMRenderLog.pageError(
                    "annotated: marks on page \(job.position) did not arrive: \(String(describing: error))"
                )
                if unfetchedPages == .strict {
                    throw PageFetchError(page: job.position, pageID: job.entry.fileBaseName, underlying: error)
                }
                return (nil, .unfetched(error))
            }
            // One unreadable page must not cost the whole document:
            // the original still goes out, only without its marks.
            do {
                let page = try await parse(data)
                return ((keep(page), page.paperSize, page.skippedBlocks), nil)
            } catch ParseError.unsupportedVersion(let version) {
                return (nil, .unsupported(version: version))
            } catch {
                RMRenderLog.pageError(
                    """
                    annotated: marks on page \(job.position) not parsed: \
                    \(String(describing: error))
                    """
                )
                return (nil, .unreadable)
            }
        }
        var unfetched: Set<Int> = []
        for (job, result) in zip(jobs, parsed) {
            marks[job.position] = result.page
            switch result.loss {
            case .unsupported(let version)?: oldVersions.append(version)
            case .unreadable?: unreadable += 1
            case .unfetched?: unfetched.insert(job.position)
            case nil: break
            }
        }

        var sheets: [Sheet<Marks>] = []
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
            sheets.append(
                Sheet(redir: page.redir, entry: entryOfPage[page.id], marks: marks[position]?.kept, sheet: sheet)
            )
        }

        // What the parser could not read is said out loud. There are no
        // ordinary reasons left in this number: the scene tree, the text and
        // the attachments are all read and count themselves only when their
        // own parse fails, so anything above zero is a piece of the page that
        // did not survive. It stands on its own — grouped with the skipped
        // count, it would vanish without a word — and it is an error
        // rather than a debug line for the same reason: a loss nobody is told
        // about is the one that ships.
        let skipped = marks.compactMap { $0 }.reduce(0) { $0 + $1.skippedBlocks }
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
        return (sheets, unfetched)
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
