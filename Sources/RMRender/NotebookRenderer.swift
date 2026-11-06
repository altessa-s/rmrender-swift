// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks
import RMLines

/// Assembling a notebook into a PDF: download the pages, parse them, draw
/// them.
public struct NotebookRenderer: Sendable {
    private let blobs: any PageBlobs

    public init(blobs: any PageBlobs) {
        self.blobs = blobs
    }

    /// A document's PDF, from its index.
    ///
    /// The page order comes from `.content`; when there is none or it does
    /// not parse, the pages go in the order of the index records — a muddled
    /// order is better than an empty file.
    /// `onProgress` is called once at the start, when the number of pages
    /// becomes known, then after each finished page, and once more when the
    /// PDF has been assembled — the last call is always `(total, total)`, so a
    /// bar driven by it ends where it said it would. Nobody knows in advance
    /// how many pages a notebook has: that is worked out from the index and
    /// `.content`, and until then showing a fraction is pointless.
    /// `paper` is the sheet to serve the document on, stated by the caller.
    /// This package draws what it is told to: whose choice the sheet is —
    /// the user's, a debugging run's, a test's — is settled a layer up.
    ///
    /// `onUnsupported` is called at most once, and only when the document
    /// holds pages of an older `.rm` generation. `onUnreadable` likewise, for
    /// pages that could not be read at all — a torn blob, a header of no known
    /// shape. Two callbacks rather than one number, because the two are
    /// different news to whoever hears them and only one of them names a
    /// cause. The renderer itself records nothing: it has bytes and no store,
    /// and handing it one would tie every caller to a store none of them
    /// asked for. The caller decides what the news is worth.
    ///
    /// `maximumPages` cuts the document to its first pages, and
    /// `includesUnlistedPages` says whether a page file `.content` does not
    /// name is drawn after the pages it does — both applied to the final page
    /// list, see `parsed`. `onPageCount` is told, once and before a page is
    /// fetched, how many pages will be drawn and how many the document has
    /// before the cut: a caller that shows "50 of 212" has no other way to
    /// learn the 212.
    ///
    /// It stands second among the callbacks, after `onProgress`, and takes
    /// two numbers, on purpose. A trailing closure finds `onProgress` scanning
    /// forwards and `onUnreadable` scanning backwards, and a one-number
    /// closure written for either cannot be taken for this one.
    ///
    /// `onMissingImages` is called at most once, when pages are drawn with a
    /// hole where an image stood: its attachment is absent from the index,
    /// failed to arrive, is past the size budget, or holds bytes that do not
    /// decode as an image. It is told how many pages lost an image and how
    /// many attachments are missing. The render goes on without them. It
    /// stands third and takes two numbers for the same reason `onPageCount`
    /// does: a one-number closure trailing an `onPageCount:` label is refused
    /// by the compiler rather than taken for it.
    public func renderPDF(
        documentID: String,
        index: DocumentFiles,
        paper: PaperSize = .a4,
        author: String? = nil,
        maximumPages: Int? = nil,
        includesUnlistedPages: Bool = true,
        onProgress: @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        onPageCount: @Sendable (_ drawn: Int, _ document: Int) -> Void = { _, _ in },
        onMissingImages: @Sendable (_ pages: Int, _ images: Int) -> Void = { _, _ in },
        onUnsupported: @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @Sendable (_ pages: Int) -> Void = { _ in }
    ) async throws -> Data {
        let work = try await measured(
            documentID: documentID,
            index: index,
            maximumPages: maximumPages,
            includesUnlistedPages: includesUnlistedPages,
            onProgress: onProgress,
            onPageCount: onPageCount,
            onMissingImages: onMissingImages,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable
        )
        let pdf = try await RenderWork.detachedWaiting { [self] in
            guard let buffer = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: buffer) else {
                throw RenderError.pdfContextUnavailable
            }
            try await draw(work, documentID: documentID, paper: paper, author: author, into: consumer)
            return buffer as Data
        }
        // The assembly counted as a unit of the work, so somebody has to say it
        // finished. Without this the bar would stop one unit short of its
        // total and stay there, and a caller with a progress bar shows what it
        // is told.
        onProgress(work.total, work.total)
        return pdf
    }

    /// The same document, written straight to `output` instead of handed back.
    ///
    /// A caller that serves a file wants a file, and the render holds every
    /// attachment and a few parsed pages while it draws. Answering with `Data`
    /// adds the finished document to that as well, for the caller to write out
    /// and drop — a full redundant copy of the output inside a process that
    /// may be killed for memory. `AnnotatedPDFRenderer` takes a URL for the
    /// same reason; this is the notebook's half of it.
    public func renderPDF(
        documentID: String,
        index: DocumentFiles,
        to output: URL,
        paper: PaperSize = .a4,
        author: String? = nil,
        maximumPages: Int? = nil,
        includesUnlistedPages: Bool = true,
        onProgress: @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        onPageCount: @Sendable (_ drawn: Int, _ document: Int) -> Void = { _, _ in },
        onMissingImages: @Sendable (_ pages: Int, _ images: Int) -> Void = { _, _ in },
        onUnsupported: @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @Sendable (_ pages: Int) -> Void = { _ in }
    ) async throws {
        let work = try await measured(
            documentID: documentID,
            index: index,
            maximumPages: maximumPages,
            includesUnlistedPages: includesUnlistedPages,
            onProgress: onProgress,
            onPageCount: onPageCount,
            onMissingImages: onMissingImages,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable
        )
        try await RenderWork.detachedWaiting { [self] in
            guard let consumer = CGDataConsumer(url: output as CFURL) else {
                throw RenderError.pdfContextUnavailable
            }
            do {
                try await draw(work, documentID: documentID, paper: paper, author: author, into: consumer)
            } catch {
                // A cancelled or failed render leaves a truncated PDF behind,
                // and a truncated PDF at the path the caller asked for is
                // worse than nothing: it opens, and it is wrong.
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        onProgress(work.total, work.total)
    }

    /// The same document as one bitmap per page — OCR's input.
    ///
    /// Reuses the fetch and parse of `renderPDF`; only the last step differs.
    /// `scale` is handed straight to `PageRenderer.image`.
    public func renderImages(
        documentID: String,
        index: DocumentFiles,
        scale: CGFloat = 1,
        grayscale: Bool = false,
        maximumPages: Int? = nil,
        includesUnlistedPages: Bool = true,
        onProgress: @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        onPageCount: @Sendable (_ drawn: Int, _ document: Int) -> Void = { _, _ in },
        onMissingImages: @Sendable (_ pages: Int, _ images: Int) -> Void = { _, _ in },
        onUnsupported: @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @Sendable (_ pages: Int) -> Void = { _ in }
    ) async throws -> [CGImage] {
        let work = try await parsed(
            documentID: documentID,
            index: index,
            maximumPages: maximumPages,
            includesUnlistedPages: includesUnlistedPages,
            onProgress: onProgress,
            onPageCount: onPageCount,
            onMissingImages: onMissingImages,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable
        )
        let images = try await renderImages(work, scale: scale, grayscale: grayscale)
        onProgress(work.total, work.total)
        return images
    }

    /// The bitmaps of a notebook already parsed. `grayscale` draws 8-bit
    /// grey rather than RGBA — a quarter of the memory for a reader of ink
    /// that sees no colour anyway.
    public func renderImages(
        _ parsed: ParsedNotebook, scale: CGFloat = 1, grayscale: Bool = false
    ) async throws -> [CGImage] {
        try await renderImages(parsed, scale: scale, grayscale: grayscale, pages: nil)
    }

    /// The pages of a window alone, in order — for a reader that takes a
    /// notebook a handful of pages at a time and holds no more than that.
    /// The parse is the caller's already, so a window costs its own pages
    /// and nothing else.
    public func renderImages(
        _ parsed: ParsedNotebook, scale: CGFloat = 1, grayscale: Bool = false, pages window: Range<Int>?
    ) async throws -> [CGImage] {
        let wanted = window.map { $0.clamped(to: 0..<parsed.pages.count) } ?? 0..<parsed.pages.count
        let images = PageRenderer.PageImages(decoded: parsed.images)
        return try await RenderWork.detached {
            try wanted.map { index in
                try PageRenderer.image(
                    page: parsed.pages[index],
                    pageSize: parsed.pageSize,
                    scale: scale,
                    images: images,
                    inkOnly: false,
                    grayscale: grayscale
                )
            }
        }
    }

    /// The handwriting alone of the pages named, by page index — for a
    /// reader of pixels that takes the typed text as text and would read
    /// it twice off a page drawn whole. The fetch and the parse are the
    /// document's once; the drawing, the costly part, is paid only for the
    /// pages asked for, since only a page with both strokes and typed text
    /// needs a second bitmap.
    public func renderInkImages(
        documentID: String,
        index: DocumentFiles,
        scale: CGFloat = 1,
        pages wanted: Set<Int>
    ) async throws -> [Int: CGImage] {
        guard !wanted.isEmpty else { return [:] }
        let work = try await parsed(documentID: documentID, index: index)
        return try await renderInkImages(work, scale: scale, pages: wanted)
    }

    /// The handwriting alone of a notebook already parsed, for the pages named.
    public func renderInkImages(
        _ parsed: ParsedNotebook, scale: CGFloat = 1, pages wanted: Set<Int>
    ) async throws -> [Int: CGImage] {
        guard !wanted.isEmpty else { return [:] }
        return try await RenderWork.detached {
            var images: [Int: CGImage] = [:]
            // `indices`, not `< count`: a negative number is as much a page
            // this notebook does not have as one past the end, and a
            // subscript below zero is a trap rather than a missing image.
            for index in wanted.sorted() where parsed.pages.indices.contains(index) {
                images[index] = try PageRenderer.image(
                    page: parsed.pages[index], pageSize: parsed.pageSize, scale: scale,
                    images: PageRenderer.PageImages(decoded: parsed.images), inkOnly: true, grayscale: false
                )
            }
            return images
        }
    }

    /// The size the document's pages are drawn at, with the same precedence
    /// the drawing uses: a page that names its own paper outranks
    /// `.content`, which outranks the tablet's default; the turn goes on
    /// last. Only the first few written pages are parsed for it: a document
    /// that names its paper names it on the first page it wrote, and one
    /// that does not would cost every page for nothing.
    public func pageGeometry(index: DocumentFiles, owner: String?) async -> PageGeometry {
        let pageEntries = index.files.filter { $0.fileExtension == "rm" }
        let layout = await layout(pageEntries, index: index, owner: owner)
        var declared: CGSize?
        for page in layout.pages.filter({ $0.entry != nil }).prefix(3) {
            guard let entry = page.entry,
                  let data = try? await blobs.data(hash: entry.hash, name: entry.name, owner: owner),
                  let parsed = try? RMParser.parsePage(data)
            else { continue }
            if let size = PageRenderer.plausibleCanvas(parsed.paperSize) {
                declared = size
                break
            }
        }
        return PageGeometry(
            pageSize: Self.canvas(declared: declared ?? layout.pageSize, isLandscape: layout.isLandscape),
            isLandscape: layout.isLandscape
        )
    }

    /// Everything up to the drawing.
    ///
    /// Split out so that the two entry points above differ in where the PDF
    /// goes and in nothing else — the fetching, the parsing, the tallies and
    /// the callbacks are one piece of work with one behaviour.
    /// Everything up to the drawing: the pages in the order the user sees
    /// them, the sheet they were written on, and their attachments — the one
    /// fetch and parse of a document, handed to whichever drawing follows.
    ///
    /// `maximumPages` and `includesUnlistedPages` act on the final page list
    /// — after the order, the tombstones, a page named twice taken as one,
    /// and the page files nobody lists — so what comes back never has more
    /// pages than the cap, whatever the file says. Pages past the cut are
    /// neither fetched nor parsed. A cap below one is taken as one: a
    /// document always comes back as at least one sheet. The count before
    /// the cut is `ParsedNotebook.documentPageCount`, and `onPageCount` is
    /// told it, beside the number that will be drawn, before a page is
    /// fetched. A document with no page at all is told `(1, 0)`: one blank
    /// sheet is drawn for it, and it has none.
    public func parsed(
        documentID: String,
        index: DocumentFiles,
        maximumPages: Int? = nil,
        includesUnlistedPages: Bool = true,
        onProgress: @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        onPageCount: @Sendable (_ drawn: Int, _ document: Int) -> Void = { _, _ in },
        onMissingImages: @Sendable (_ pages: Int, _ images: Int) -> Void = { _, _ in },
        onUnsupported: @Sendable (_ pages: Int) -> Void = { _ in },
        onUnreadable: @Sendable (_ pages: Int) -> Void = { _ in }
    ) async throws -> ParsedNotebook {
        let work = try await walk(
            documentID: documentID,
            index: index,
            maximumPages: maximumPages,
            includesUnlistedPages: includesUnlistedPages,
            onProgress: onProgress,
            onPageCount: onPageCount,
            onMissingImages: onMissingImages,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable
        ) { $0 }
        return ParsedNotebook(
            pages: work.pages,
            pageSize: work.pageSize,
            assets: work.assets,
            unreadable: work.unreadable,
            pageIDs: work.pageIDs,
            documentPageCount: work.documentPageCount,
            total: work.total,
            images: work.images
        )
    }

    /// The same walk for a render that draws as it goes: every page is
    /// fetched and parsed for what has to be known before the first one is
    /// drawn — the sheet the page declares, the attachments it shows, the
    /// tallies — and let go. `draw(_:…)` parses each again when it comes to
    /// it. Kept, every page stood parsed for the length of the render — about
    /// a quarter of a megabyte for a page written full, and a long notebook
    /// has thousands.
    private func measured(
        documentID: String,
        index: DocumentFiles,
        maximumPages: Int?,
        includesUnlistedPages: Bool,
        onProgress: @Sendable (_ completed: Int, _ total: Int) -> Void,
        onPageCount: @Sendable (_ drawn: Int, _ document: Int) -> Void,
        onMissingImages: @Sendable (_ pages: Int, _ images: Int) -> Void,
        onUnsupported: @Sendable (_ pages: Int) -> Void,
        onUnreadable: @Sendable (_ pages: Int) -> Void
    ) async throws -> Walk<Void> {
        try await walk(
            documentID: documentID,
            index: index,
            maximumPages: maximumPages,
            includesUnlistedPages: includesUnlistedPages,
            onProgress: onProgress,
            onPageCount: onPageCount,
            onMissingImages: onMissingImages,
            onUnsupported: onUnsupported,
            onUnreadable: onUnreadable
        ) { _ in }
    }

    /// Where a page of the walk comes from, so that it can be had again.
    private enum PageSource: Sendable {
        /// Never drawn on: a sheet with its ruling and nothing to fetch.
        case blank(template: String?)
        /// Did not parse, or is of an older generation: a blank sheet that
        /// counts a block lost, as the walk made it.
        case unread(template: String?)
        /// A page file, parsed when it is wanted.
        case file(DocumentFile, template: String?)
    }

    /// One walk of a document: the pages in the order the user sees them,
    /// with `keep`'s share of each, and everything about the document the
    /// drawing has to know before its first page.
    private struct Walk<Kept: Sendable>: Sendable {
        let pages: [Kept]
        /// Where each of `pages` came from, in step with it.
        let sources: [PageSource]
        let pageSize: CGSize
        /// The attachments that decoded, as bytes and as the images the
        /// check made of them.
        let assets: [String: Data]
        let images: [String: CGImage]
        let unreadable: Set<Int>
        let pageIDs: [String?]
        let documentPageCount: Int
        let total: Int
    }

    /// The page `source` names, as the walk had it: the same blank sheets,
    /// and a page file parsed again. The bytes are the ones the walk read —
    /// a blob is named by its hash — so a page that parsed then parses now;
    /// one that does not fails the render rather than quietly turning into
    /// a blank sheet the tallies never counted.
    private func page(_ source: PageSource, documentID: String, position: Int) async throws -> RMPage {
        switch source {
        case .blank(let template):
            return RMPage(strokes: [], skippedBlocks: 0).with(templateName: template)
        case .unread(let template):
            return RMPage(strokes: [], skippedBlocks: 1).with(templateName: template)
        case .file(let entry, let template):
            let data = try await blobs.data(hash: entry.hash, name: entry.name, owner: documentID)
            do {
                return try await parse(data).with(templateName: template)
            } catch {
                throw RenderError.malformedPage(
                    "page \(position) parsed when measured and not when drawn: \(String(describing: error))"
                )
            }
        }
    }

    /// A measured document drawn into `consumer`, each page parsed as the
    /// drawing comes to it — a few ahead, beside the drawing — and let go
    /// once it is on the page.
    private func draw(
        _ work: Walk<Void>,
        documentID: String,
        paper: PaperSize,
        author: String?,
        into consumer: CGDataConsumer
    ) async throws {
        let output = try PageRenderer.PDFPages(
            consumer: consumer, pageSize: work.pageSize, paper: paper, author: author
        )
        let images = PageRenderer.PageImages(decoded: work.images)
        let sources = work.sources
        try await RenderWork.boundedConcurrentForEach(Array(sources.indices)) { [self] position in
            try await page(sources[position], documentID: documentID, position: position)
        } consume: { _, page in
            // A caller may cancel a render it does not need, and drawing is
            // the long part of it. Asked between pages: a page is a bounded
            // piece of work, and stopping between two of them costs nothing
            // to reason about.
            try Task.checkCancellation()
            output.draw(page, images: images)
        }
        output.close()
    }

    /// Everything up to the drawing, with `keep` deciding what of each
    /// parsed page is held: all of it for `parsed`, nothing for a render
    /// that parses again as it draws. What the walk itself needs of a page —
    /// its declared sheet, its attachments, its lost blocks — is taken where
    /// the page is parsed, so a page `keep` lets go is gone before the next
    /// is read.
    private func walk<Kept: Sendable>(
        documentID: String,
        index: DocumentFiles,
        maximumPages: Int?,
        includesUnlistedPages: Bool,
        onProgress: @Sendable (_ completed: Int, _ total: Int) -> Void,
        onPageCount: @Sendable (_ drawn: Int, _ document: Int) -> Void,
        onMissingImages: @Sendable (_ pages: Int, _ images: Int) -> Void,
        onUnsupported: @Sendable (_ pages: Int) -> Void,
        onUnreadable: @Sendable (_ pages: Int) -> Void,
        keep: @escaping @Sendable (RMPage) -> Kept
    ) async throws -> Walk<Kept> {
        let pageEntries = index.files.filter { $0.fileExtension == "rm" }
        let layout = await layout(
            pageEntries,
            index: index,
            owner: documentID,
            includesUnlistedPages: includesUnlistedPages,
            maximumPages: maximumPages
        )
        // A document with no page at all is still drawn as one blank sheet, so
        // that is what `drawn` says; `document` stays nought.
        onPageCount(max(layout.pages.count, 1), layout.documentPageCount)

        // A notebook nobody has written in yet. Its pages exist in `.content`
        // and have no `.rm` blob behind them — the tablet writes one when the
        // first stroke lands. Refusing to render would leave the caller with
        // no document at all; a blank sheet is what the tablet shows for such
        // a notebook, so a blank
        // sheet is what we serve. The blank pages themselves are filled in below,
        // from the layout; this branch is the last resort — nothing in
        // `.content` and nothing drawn either.
        guard !layout.pages.isEmpty else {
            RMRenderLog.pageError(
                "render: \(documentID) has no pages at all — one blank sheet stands for it"
            )
            // One unit for the one sheet; the caller closes it after drawing.
            return Walk(
                pages: [keep(RMPage(strokes: [], skippedBlocks: 0))],
                sources: [.blank(template: nil)],
                pageSize: layout.pageSize,
                assets: [:],
                images: [:],
                unreadable: [],
                pageIDs: [nil],
                documentPageCount: 0,
                total: 1
            )
        }

        // The last step is assembling the PDF out of the already parsed
        // pages. It is noticeable, so it counts as a page of its own:
        // otherwise the bar would freeze at a hundred per cent while the
        // render runs.
        let total = layout.pages.count + 1
        onProgress(0, total)

        // Pages are fetched and parsed with a bounded fan-out
        // (`RenderWork.boundedConcurrentMap`, shared with the annotated-PDF
        // route). Fetching them one after another would make the user pay one
        // network round trip per page before the render could even start:
        // seconds on a fifty-page notebook. The result is put back into
        // document order — the PDF and the "declared size wins" rule below
        // both depend on it.
        var slots: [Measured<Kept>?] = Array(repeating: nil, count: layout.pages.count)
        var sources: [PageSource] = layout.pages.map { page in
            page.entry.map { .file($0, template: page.template) } ?? .blank(template: page.template)
        }
        // Pages that were never drawn on: nothing to fetch and nothing to
        // parse, only the ruling they were created with. Filled in before the
        // group starts so that the fan-out below is over real blobs alone.
        var blanks = 0
        for (position, page) in layout.pages.enumerated() where page.entry == nil {
            slots[position] = Measured(RMPage(strokes: [], skippedBlocks: 0).with(templateName: page.template), keep)
            blanks += 1
        }
        if blanks > 0 {
            RMRenderLog.pageDebug("render: \(blanks) pages have never been drawn on — blank sheets")
        }

        // The versions of the pages that turned out to be of an older
        // generation. Gathered rather than counted, because the number is what
        // goes into the log: "three pages of version 5" is a fact about the
        // notebook, while "three pages unread" is a fact about us.
        var oldVersions: [Int] = []
        // Pages that came back as nothing at all. Counted rather than
        // gathered: there is no fact about them to gather — that is the whole
        // difference between this tally and the one above.
        var unreadable = 0
        var unreadPositions: Set<Int> = []

        // The pages that do have bytes, with the place in the document each
        // has to come back to. Worked out up front so that the fan-out below
        // is over jobs alone: a hole skipped inside the scheduler would have
        // to be skipped identically by whatever counts progress.
        let jobs: [(position: Int, entry: DocumentFile, template: String?)] =
            layout.pages.enumerated().compactMap { position, page in
                page.entry.map { (position, $0, page.template) }
            }

        // The blanks are already done: counting them in keeps the bar
        // honest on a notebook that is mostly empty.
        onProgress(blanks, total)
        let parsed = try await RenderWork.boundedConcurrentMap(
            jobs,
            onCompleted: { onProgress(blanks + $0, total) },
            { [self] job -> (page: Measured<Kept>, version: Int?, unreadable: Bool) in
                // The owner travels with the bytes, exactly as it does in
                // `AnnotatedPDFRenderer`: a cache that is not told whose a
                // blob is keeps nothing, so every one of these pages would be
                // downloaded afresh on every render.
                let data = try await blobs.data(
                    hash: job.entry.hash, name: job.entry.name, owner: documentID
                )
                // One unreadable page must not cancel the whole document:
                // an empty one takes its place — but with a template, so
                // that the loss does not look like a blank sheet.
                //
                // A page of an older generation goes down the very same
                // road, and deliberately so: it keeps its place in the
                // document, so the numbering of everything after it does
                // not shift under the loss. What it does not do is pass in
                // silence — the version travels back with it.
                do {
                    let page = try await parse(data)
                    return (Measured(page.with(templateName: job.template), keep), nil, false)
                } catch ParseError.unsupportedVersion(let version) {
                    let blank = RMPage(strokes: [], skippedBlocks: 1)
                    return (Measured(blank.with(templateName: job.template), keep), version, false)
                } catch {
                    // Anything else is a page we cannot name: bytes that
                    // are not a header, a header of a generation with no
                    // number in it, a blob that arrived short. It reaches
                    // the caller as well as the log, because the sheet it
                    // turns into is indistinguishable from a page nobody
                    // wrote on — and the user is the one who knows which
                    // it should have been.
                    RMRenderLog.pageError(
                        """
                        render: page \(job.position) not parsed: \
                        \(String(describing: error))
                        """
                    )
                    let blank = RMPage(strokes: [], skippedBlocks: 1)
                    return (Measured(blank.with(templateName: job.template), keep), nil, true)
                }
            }
        )
        for (job, result) in zip(jobs, parsed) {
            slots[job.position] = result.page
            if let version = result.version { oldVersions.append(version) }
            if result.unreadable { unreadable += 1 }
            if result.unreadable || result.version != nil {
                unreadPositions.insert(job.position)
                sources[job.position] = .unread(template: job.template)
            }
        }
        let pages = slots.compactMap { $0 }

        // Even a notebook where every page is of an older generation comes out
        // as a PDF of blank sheets rather than as a refusal. Refusing would
        // leave the caller with no document at all, and a document that
        // promises to open and does not is worse than one that opens blank.
        // The sheets say nothing on their own, which is why the callback
        // below is the other half of the answer.
        if !oldVersions.isEmpty {
            RMRenderLog.pageError(
                """
                render: \(documentID) has \
                \(oldVersions.count) of \(pages.count) pages in \
                an older .rm format (versions \(Set(oldVersions).sorted().map(String.init).joined(separator: ", "))) \
                — they are served blank
                """
            )
            onUnsupported(oldVersions.count)
        }

        if unreadable > 0 {
            RMRenderLog.pageError(
                """
                render: \(documentID) has \
                \(unreadable) of \(pages.count) pages \
                that could not be read at all — they are served blank
                """
            )
            onUnreadable(unreadable)
        }

        // Every block type this version knows is read, and each counts itself
        // only when its own parse fails, so this counts real loss rather than
        // housekeeping: above zero means a piece of somebody's page did not
        // come through. Hence an error rather than a debug line — at debug it
        // is invisible by default, which is the same as not saying it.
        let skipped = pages.reduce(0) { $0 + $1.skippedBlocks }
        if skipped > 0 {
            RMRenderLog.pageError(
                """
                render: \(skipped) blocks across \
                \(pages.count) pages could not be read
                """
            )
        }

        // The page size from the page itself outranks the one declared in
        // `.content`: with `zoomMode: bestFit` the latter holds the state of
        // a manual zoom left over from another device. On a notebook from
        // a Paper Pro that gives a sheet of 1404 × 1872 instead of
        // 1620 × 2160 — the template and the handwriting drift apart,
        // because the first is built from the sheet size while the second is
        // centred on half of it.
        //
        // The page's word is weighed like `.content`'s: a scene block can say
        // `1e300` as easily, and a size no page could have is a size not said.
        let declared = pages.lazy.compactMap { PageRenderer.plausibleCanvas($0.paperSize) }.first
        // The turn goes on last, over whichever size won above — and it has to
        // be here rather than beside the `.content` reading, because the scene
        // block records no orientation at all: a notebook written sideways is
        // byte-identical to an upright one. A landscape document whose pages
        // carry a scene size — which is the ordinary case, and the reason this
        // precedence exists — would otherwise have its turn silently overruled
        // and come out upright.
        let fetched = await assets(Set(pages.flatMap(\.imageFiles)), index: index, owner: documentID)
        let images = PageAssets.decoded(fetched, channel: "render")
        let holes = PageAssets.holes(in: pages.map(\.imageFiles), available: Set(images.keys))
        if holes.pages > 0 { onMissingImages(holes.pages, holes.images) }
        return Walk(
            pages: pages.map(\.kept),
            sources: sources,
            pageSize: Self.canvas(declared: declared ?? layout.pageSize, isLandscape: layout.isLandscape),
            assets: fetched.filter { images[$0.key] != nil },
            images: images,
            unreadable: unreadPositions,
            pageIDs: layout.pages.map { $0.entry?.fileBaseName },
            documentPageCount: layout.documentPageCount,
            total: total
        )
    }

    /// What the walk keeps of a page — `keep`'s share — and what it needs of
    /// it itself, taken while the page is at hand.
    private struct Measured<Kept: Sendable>: Sendable {
        let kept: Kept
        let paperSize: CGSize?
        let imageFiles: [String]
        let skippedBlocks: Int

        init(_ page: RMPage, _ keep: (RMPage) -> Kept) {
            kept = keep(page)
            paperSize = page.paperSize
            imageFiles = page.images.map(\.file)
            skippedBlocks = page.skippedBlocks
        }
    }

    /// One page of a document, in the order the user sees it.
    public struct OrderedPage: Sendable {
        /// The blob behind it, or `nil` for a page never drawn on: it is
        /// listed in `.content` and has no `.rm` until the first stroke.
        public let entry: DocumentFile?
        public let template: String?
        /// For a document built on an imported PDF, which page of that file
        /// this one stands on, counting from zero; `nil` for a page added
        /// on the tablet, and for a notebook.
        public let redir: Int?
    }

    /// The document's pages in reading order, tombstones dropped.
    ///
    /// Here for the tools that report page by page. Walking the index instead
    /// gives the order the blobs happen to lie in, which is not the order
    /// anybody sees — and a report in that order is worse than no report,
    /// because it looks like the right one.
    ///
    /// `maximumPages` and `includesUnlistedPages` mean what they mean to
    /// `parsed`, so the list answered here is the list a render with the same
    /// two draws; with neither, its count is the document's page count.
    public func orderedPages(
        index: DocumentFiles,
        maximumPages: Int? = nil,
        includesUnlistedPages: Bool = true
    ) async -> [OrderedPage] {
        let pageEntries = index.files.filter { $0.fileExtension == "rm" }
        return await layout(
            pageEntries,
            index: index,
            owner: nil,
            includesUnlistedPages: includesUnlistedPages,
            maximumPages: maximumPages
        ).pages.map {
            OrderedPage(entry: $0.entry, template: $0.template, redir: $0.redir)
        }
    }

    /// The bytes of the pages' attachments, by file name.
    ///
    /// An image on a page is a blob of the document's own index, one level
    /// deeper than a page — `<document>/<page>/<uuid>.png` — and until it is
    /// fetched the page has a hole where the user sees a picture. A missing
    /// or unreadable attachment costs its own image and nothing else.
    private func assets(
        _ wanted: Set<String>,
        index: DocumentFiles,
        owner: String?
    ) async -> [String: Data] {
        await PageAssets.gather(wanted, index: index, channel: "render") { entry in
            try await blobs.data(hash: entry.hash, name: entry.name, owner: owner)
        }
    }

    /// Parsing and rendering are taken off the actor: both are pure
    /// computation and on a large notebook take a noticeable amount of time.
    private func parse(_ data: Data) async throws -> RMPage {
        try await RenderWork.detached { try RMParser.parsePage(data) }
    }

    /// The pages in the right order, with template names and the sheet size.
    ///
    /// The entry is optional because a page can exist without bytes: a
    /// notebook page that has never been written on is listed in `.content`
    /// and has no `.rm` blob until the first stroke.
    struct Layout {
        let pages: [(entry: DocumentFile?, template: String?, redir: Int?)]
        /// The size `.content` declared, upright as it stands there. Turning
        /// it happens once, later, and only after the page's own size has had
        /// its say — see `renderPDF`.
        let pageSize: CGSize
        let isLandscape: Bool
        /// How many pages the list held before `maximumPages` cut it.
        var documentPageCount: Int

        init(
            pages: [(entry: DocumentFile?, template: String?, redir: Int?)],
            pageSize: CGSize,
            isLandscape: Bool
        ) {
            self.pages = pages
            self.pageSize = pageSize
            self.isLandscape = isLandscape
            documentPageCount = pages.count
        }

        /// The same layout cut to its first `maximumPages` — the cap goes on
        /// last, over the list every other rule has already settled, so
        /// nothing recovered or repeated after it can carry a document past
        /// it. Below one is taken as one: a document is at least one sheet.
        func capped(at maximumPages: Int?) -> Layout {
            guard let maximumPages, pages.count > max(maximumPages, 1) else { return self }
            var cut = Layout(
                pages: Array(pages.prefix(max(maximumPages, 1))),
                pageSize: pageSize,
                isLandscape: isLandscape
            )
            cut.documentPageCount = documentPageCount
            return cut
        }
    }

    /// `owner` is the document the `.content` blob belongs to, for a caller
    /// that keeps a cache — `nil` from the two public questions below, which
    /// are asked about a document nobody is rendering.
    ///
    /// `includesUnlistedPages` drops the page files a page list leaves out;
    /// where there is no page list at all — no `.content`, one that does not
    /// parse, one that names nothing — every page file is the document and
    /// none of them is unlisted. `maximumPages` is the cut, made last.
    private func layout(
        _ entries: [DocumentFile],
        index: DocumentFiles,
        owner: String?,
        includesUnlistedPages: Bool = true,
        maximumPages: Int? = nil
    ) async -> Layout {
        await uncappedLayout(entries, index: index, owner: owner, includesUnlistedPages: includesUnlistedPages)
            .capped(at: maximumPages)
    }

    private func uncappedLayout(
        _ entries: [DocumentFile],
        index: DocumentFiles,
        owner: String?,
        includesUnlistedPages: Bool
    ) async -> Layout {
        // `isLandscape` is a parameter rather than a constant `false` because
        // this fallback is reached with a `.content` in hand as well — one
        // that named no pages. Losing the switch there would leave the
        // document upright for want of a page list, which has nothing to do
        // with which way round it is.
        func inIndexOrder(
            _ pageSize: CGSize = PageRenderer.defaultPageSize,
            isLandscape: Bool = false
        ) -> Layout {
            Layout(
                pages: Self.unique(entries).map { (Optional($0), nil, nil) },
                pageSize: pageSize,
                isLandscape: isLandscape
            )
        }

        guard let contentEntry = index.file(withExtension: "content"),
              let data = try? await blobs.data(
                  hash: contentEntry.hash, name: contentEntry.name, owner: owner
              )
        else {
            RMRenderLog.pageDebug("render: document has no .content — no templates")
            return inIndexOrder()
        }

        let content: PageOrder.Layout
        do {
            content = try PageOrder.layout(from: data)
        } catch {
            // A silent fallback here would be the most galling of all: the
            // pages get drawn, just without templates, and the reason stays
            // invisible.
            RMRenderLog.pageError("render: .content not parsed: \(String(describing: error))")
            return inIndexOrder()
        }

        let pageSize = content.pageSize ?? PageRenderer.defaultPageSize

        guard !content.pages.isEmpty || !content.deleted.isEmpty else {
            RMRenderLog.pageDebug("render: no pages in .content")
            return inIndexOrder(pageSize, isLandscape: content.isLandscape)
        }

        RMRenderLog.pageDebug(
            """
            render: pages in .content \(content.pages.count), \
            with templates \(content.pages.filter { $0.template != nil }.count), \
            page \(pageSize.width)×\(pageSize.height)
            """
        )

        return Layout(
            pages: Self.order(
                content.pages,
                entries: entries,
                deleted: content.deleted,
                includesUnlisted: includesUnlistedPages
            ),
            pageSize: pageSize,
            isLandscape: content.isLandscape
        )
    }

    /// The canvas a document's pages stand on.
    ///
    /// A landscape document is not an upright one turned over at the end. The
    /// tablet hands its template evaluator the page's own width as
    /// `templateWidth`, and the landscape templates are written against the
    /// long edge: `LS Piano sheet` runs its staves out to x = 1743 and the
    /// storyboards to x = 1812, neither of which a 1404-wide page holds
    /// (true of the tablet's landscape templates generally). So the canvas
    /// itself lies on its side, and the handwriting is laid out against that
    /// same canvas — which is why nothing here rotates anything: it is the
    /// sheet that differs, not the drawing on it.
    ///
    /// A declared size is trusted when it already agrees. It is turned only
    /// when the document says landscape and the size it declared — or the
    /// default it fell back to — is still upright.
    static func canvas(declared: CGSize?, isLandscape: Bool) -> CGSize {
        let size = declared ?? PageRenderer.defaultPageSize
        guard isLandscape, size.height > size.width else { return size }
        return CGSize(width: size.height, height: size.width)
    }

    /// The pages of `.content` paired with the blobs that hold them.
    ///
    /// A pure function, because this is the part worth holding still: what the
    /// document says its pages are, what has actually been written, and what to
    /// do when the two disagree. A page named in `.content` with no blob behind
    /// it keeps its place and its ruling — it is a page the user has not
    /// written on, not a page that is missing. A blob named by nothing in
    /// `.content` is appended rather than dropped: whatever it is, its strokes
    /// are the user's — unless the caller said `includesUnlisted: false`.
    /// Explicitly deleted pages are never recovered this way.
    ///
    /// Every page comes out once. A page `.content` names twice is one page
    /// where it first stands — `PageOrder` sees to that, and it is done again
    /// here so the promise does not hang on who built the list — and a page
    /// file is appended at most once, and never when its page is listed,
    /// however many records of the index carry it.
    static func order(
        _ pages: [PageOrder.Page],
        entries: [DocumentFile],
        deleted: Set<String> = [],
        includesUnlisted: Bool = true
    ) -> [(entry: DocumentFile?, template: String?, redir: Int?)] {
        // Page records are named `<document>/<page>.rm`.
        var byPageID: [String: DocumentFile] = [:]
        for entry in entries {
            byPageID[entry.fileBaseName] = entry
        }

        let listed = PageOrder.unique(pages)
        let sorted = listed.map { (entry: byPageID[$0.id], template: $0.template, redir: $0.redir) }
        guard includesUnlisted else { return sorted }
        let taken = Set(listed.map(\.id))
        let missing = unique(entries)
            .filter { !taken.contains($0.fileBaseName) && !deleted.contains($0.fileBaseName) }
            .map { (entry: Optional($0), template: String?.none, redir: Int?.none) }
        return sorted + missing
    }

    /// The page files in the order of their names, one per page: two records
    /// of the index for the same page file are one page, not two.
    static func unique(_ entries: [DocumentFile]) -> [DocumentFile] {
        var seen: Set<String> = []
        return entries
            .sorted { $0.name < $1.name }
            .filter { seen.insert($0.fileBaseName).inserted }
    }
}

/// Parsing the `.content` file. The file comes in two known forms; both are
/// parsed, and finding nothing is calmly accepted.
enum PageOrder {
    /// A page of a document: the identifier, the template name, and — for a
    /// document built on an imported PDF — the page of that file this one
    /// stands on.
    struct Page: Sendable, Hashable {
        let id: String
        let template: String?
        /// Which page of the imported PDF is behind this one, counting from
        /// zero. `nil` means there is none: the page was added on the tablet.
        ///
        /// Read off a real export: an inserted page carries **no `redir` key
        /// at all** — not `-1`, not a null value. A reader that looks for a
        /// sentinel finds nothing and quietly puts the page on top of the
        /// wrong original.
        let redir: Int?
        /// The file named an original page here and the number was refused —
        /// below zero, past the original, or not a whole number at all — so
        /// `redir` is `nil` for a reason a reader of the log should hear,
        /// unlike a page that never claimed one.
        var refusedRedir = false
    }

    /// Everything the renderer needs out of `.content`.
    struct Layout: Sendable {
        let pages: [Page]
        /// Tombstones must survive parsing so index recovery cannot resurrect them.
        let deleted: Set<String>
        /// The sheet size, if the document declared one.
        let pageSize: CGSize?
        /// The document's own orientation switch.
        ///
        /// Not "was written with the tablet held sideways": turning the device
        /// is its own state and reaches no file at all — a notebook written
        /// that way is byte-identical to an upright one, `.content` and
        /// `.metadata` included. Only this explicit field says anything, so
        /// only it is read.
        let isLandscape: Bool
    }

    struct Content: Decodable {
        struct Pages: Decodable {
            struct Entry: Decodable {
                /// Values in `.content` are wrapped in an object with a
                /// timestamp: `{"timestamp": "2:1", "value": "P US Legal"}`.
                struct Stamped: Decodable { let value: String? }
                struct StampedNumber: Decodable { let value: Int? }
                let id: String
                let template: Stamped?
                /// Read through a form that cannot fail: a `redir` of the
                /// wrong shape — a fraction, a string, a number past what an
                /// `Int` holds — is one page without an original, not a
                /// `.content` that does not decode and takes every page's
                /// order and template with it.
                let redir: StampedIndex?
                /// The tombstone. A relayout does not take a record out of
                /// the list — it marks it `{"value": 1}` and the record stays
                /// forever. Dead is `value: 1` exactly: a record with `value:
                /// 0` is alive — the trace of an edit winning over a deletion
                /// — and so is one with no key.
                let deleted: StampedNumber?
                /// The CRDT order key (`"ba"`, `"bb"`, `"bc"`…). The order of
                /// the array is not the order of the pages: tombstones and
                /// reordered pages drift to the tail.
                let idx: Stamped?
            }
            let pages: [Entry]?
        }
        /// A field the tablet writes plainly — `"orientation": "landscape"`,
        /// beside the reader settings — while its neighbours in the same file
        /// come wrapped in a timestamp. Read through a form that takes either,
        /// because the cost of guessing wrong is not a missing field but a
        /// page turned the wrong way.
        struct Orientation: Decodable {
            let value: String?

            private struct Stamped: Decodable { let value: String? }

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let plain = try? container.decode(String.self) {
                    value = plain
                } else {
                    value = (try? container.decode(Stamped.self))?.value
                }
            }
        }

        /// A page number of the imported file as the file wrote it, or `nil`
        /// where what it wrote is not one. Never throws: one bad number
        /// costs its own page its original and nothing else.
        struct PageIndex: Decodable {
            let value: Int?
            /// Something other than `null` stood there — so a `nil` value
            /// is a number refused, not a number never given.
            let present: Bool

            init(from decoder: any Decoder) throws {
                let container = try? decoder.singleValueContainer()
                present = container.map { !$0.decodeNil() } ?? true
                value = try? container?.decode(Int.self)
            }
        }

        /// `{"timestamp": "1:2", "value": 3}`, read as leniently as
        /// `PageIndex` and for the same reason.
        struct StampedIndex: Decodable {
            let value: Int?
            /// See `PageIndex.present`: a record that carries anything but
            /// `null` here claims an original page, and one whose claim does
            /// not read as a number fails to name it.
            let present: Bool

            private enum CodingKeys: String, CodingKey { case value }

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    // `"redir": 3`, `"redir": "x"` — something, in a shape
                    // that is not the stamped one.
                    value = nil
                    present = true
                    return
                }
                let index = try? container.decodeIfPresent(PageIndex.self, forKey: .value)
                value = index?.value
                present = index?.present ?? (container.contains(.value) && (try? container.decodeNil(forKey: .value)) != true)
            }
        }

        let cPages: Pages?
        let pages: [String]?
        /// `"portrait"` unless the user threw the document's own switch.
        let orientation: Orientation?
        /// The flat form of the same mapping: page *i* of the document
        /// stands on page `redirectionPageMap[i]` of the imported file. Both
        /// forms are live — for example, a one-page document carried
        /// this one, a five-page document carried `cPages`.
        let redirectionPageMap: [PageIndex]?
        /// The page size. It sits next to the zoom settings, but it is the
        /// sheet all right: on a notebook from the tablet, 1404×1872.
        let customZoomPageWidth: Double?
        let customZoomPageHeight: Double?
    }

    static func layout(from data: Data) throws -> Layout {
        let content = try JSONDecoder().decode(Content.self, from: data)

        // Only a size a page could have: `1e300` decodes as a perfectly good
        // `Double` and is no sheet at all (`PageRenderer.plausibleCanvas`).
        var pageSize: CGSize?
        if let width = content.customZoomPageWidth, let height = content.customZoomPageHeight {
            pageSize = PageRenderer.plausibleCanvas(CGSize(width: width, height: height))
        }

        let isLandscape = content.orientation?.value == "landscape"

        if let pages = content.cPages?.pages, !pages.isEmpty {
            // Only the living, and in the declared order. A document whose
            // layout settings were switched a few times carries more
            // tombstones than pages — 30 records for 9 living on one live
            // EPUB — and each tombstone duplicates the `idx` and `redir` of a
            // living page. The array order is no substitute for the key:
            // tombstones and reordered pages drift to the tail.
            let living = pages.enumerated().filter { $0.element.deleted?.value != 1 }
            let ordered = living.sorted { left, right in
                // Lexicographic — `idx` is a fractional key, and among the
                // living it is unique. A record without one keeps its place
                // in the array, before any keyed neighbour it stood ahead of.
                let leftKey = left.element.idx?.value ?? ""
                let rightKey = right.element.idx?.value ?? ""
                return leftKey == rightKey ? left.offset < right.offset : leftKey < rightKey
            }
            return Layout(
                pages: unique(ordered.map {
                    page(
                        id: $0.element.id,
                        template: $0.element.template?.value,
                        redir: $0.element.redir?.value,
                        claimed: $0.element.redir?.present ?? false
                    )
                }),
                deleted: Set(pages.filter { $0.deleted?.value == 1 }.map(\.id)),
                pageSize: pageSize,
                isLandscape: isLandscape
            )
        }
        // The flat form: the order only, no templates, and the mapping to the
        // imported file as a flat array beside it. Matched by position before
        // the duplicates go, so a page named twice keeps the number of the
        // place it first stood in.
        let redirects = content.redirectionPageMap
        return Layout(
            pages: unique((content.pages ?? []).enumerated().map { position, id in
                let entry = redirects.flatMap { position < $0.count ? $0[position] : nil }
                return page(id: id, template: nil, redir: entry?.value, claimed: entry?.present ?? false)
            }),
            deleted: [],
            pageSize: pageSize,
            isLandscape: isLandscape
        )
    }

    /// A page named twice is one page, where it first stands.
    ///
    /// Nothing the tablet writes names a living page twice, and a renderer
    /// that drew one twice would hand a file of a hundred thousand copies of
    /// one record a hundred thousand sheets. The first place wins because it
    /// is the one a reader of the list meets first.
    static func unique(_ pages: [Page]) -> [Page] {
        var seen: Set<String> = []
        return pages.filter { seen.insert($0.id).inserted }
    }

    /// A page whose `redir` can name a page of something: none counts below
    /// zero. Whether the imported file has that many pages is a question only
    /// the file can answer — see `checked(_:originalPages:)`. `claimed` is
    /// whether the file put anything there at all, so a refused number is
    /// told from an absent one.
    private static func page(id: String, template: String?, redir: Int?, claimed: Bool) -> Page {
        guard let redir, redir >= 0 else {
            return Page(id: id, template: template, redir: nil, refusedRedir: claimed)
        }
        return Page(id: id, template: template, redir: redir)
    }

    /// The pages with every `redir` the imported file cannot honour taken
    /// away: one at or past its page count stands on no original, and is
    /// drawn as a page added on the tablet would be — on blank paper.
    ///
    /// Checked here, once, against the file itself, rather than trusted at
    /// the place a page is looked up: the number arrives from a file anybody
    /// can write, and `Int.max` plus the one CoreGraphics counts from is a
    /// trap rather than an error.
    static func checked(_ pages: [Page], originalPages: Int) -> [Page] {
        pages.map { page in
            guard let redir = page.redir, redir >= 0, redir < originalPages else {
                return page.redir == nil ? page : Page(id: page.id, template: page.template, redir: nil, refusedRedir: true)
            }
            return page
        }
    }

    static func pages(from data: Data) throws -> [Page] {
        try layout(from: data).pages
    }
}
