// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import RMMarks
import RMLines
@testable import RMRender
import Synchronization
import Testing

// Marks on an imported PDF, a cancelled render, and the two ways out.

// MARK: - What a renderer asks of the world

/// Where a renderer gets its bytes — the double for a real blob store.
///
/// `PageBlobs` is the whole of it: a blob by its address, and nothing about
/// the network, the cache or the index. That makes `renderPDF` itself
/// reachable from a test. Exercised only through the pieces underneath them,
/// both renderers would leave out the one piece where a difference between
/// the two routes hides.
private final class FixtureBlobs: PageBlobs, Sendable {
    private let blobs: [String: Data]
    /// Run as each blob is asked for, before it is handed over. A test that
    /// has to act while a render is in flight has no other moment to do it.
    private let onFetch: @Sendable (String) async -> Void

    init(_ blobs: [String: Data], onFetch: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.blobs = blobs
        self.onFetch = onFetch
    }

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        await onFetch(hash)
        guard let bytes = blobs[hash] else { throw RenderError.malformedPage(name) }
        return bytes
    }

    func file(
        hash: String,
        name: String,
        owner: String?,
        size: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        let bytes = try await data(hash: hash, name: name, owner: owner)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rmrender-test-\(UUID().uuidString).blob")
        try bytes.write(to: url)
        onProgress(Int64(bytes.count), Int64(bytes.count))
        // Made for this call, so the renderer is the one that deletes it —
        // and whether it does is part of what these tests watch.
        return BlobFile(url: url, isTemporary: true)
    }
}

/// A blob's address. The real store is content-addressed, so two identical
/// files are one blob; keeping that here means a fixture cannot accidentally
/// depend on two pages being told apart by anything but their bytes.
private func address(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// A PDF of blank pages with a grey square on each — an imported file, in the
/// shape a printer or a scanner writes.
private func blankPDF(pages: Int, size: CGSize) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    var box = CGRect(origin: .zero, size: size)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        // Small on purpose. It is there so the imported page has a drawing of
        // its own to keep, and no larger, because the comparisons below count
        // the ink of a whole page: a square that outweighs the marks would
        // hide a difference in the marks inside its own rounding.
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 20, y: 20, width: 30, height: 30))
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

/// The dark pixels of one page of a PDF file, rasterised through CoreGraphics.
///
/// Through CoreGraphics rather than PDFKit for the reason the overlay tests
/// give: a mark only PDFKit can see is a mark other PDF readers will not
/// show.
///
/// `within` narrows the count to a rectangle of the page, in the page's own
/// coordinates. A whole page is the right question for "did the two routes
/// draw the same thing"; it is the wrong one for "did the eraser take
/// anything off", because the imported sheet's own drawing outweighs a stroke
/// by an order of magnitude and would hide the hole entirely.
private func inkOfPage(_ url: URL, page: Int, within region: CGRect? = nil) throws -> Int {
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let pdfPage = try #require(document.page(at: page))
    let box = region ?? pdfPage.getBoxRect(.mediaBox)
    let width = Int(box.width), height = Int(box.height)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A page whose box does not begin at zero draws in its own coordinates.
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(pdfPage)
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    return stride(from: 0, to: width * height * 4, by: 4).count { Int(buffer[$0]) < 200 }
}

private func boxOfPage(_ url: URL, page: Int) throws -> CGRect {
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    return try #require(document.page(at: page)).getBoxRect(.mediaBox)
}

// MARK: - The two ways marks reach an imported PDF

/// A document made of an imported PDF and one page of marks over it.
private struct AnnotatedFixture {
    let index: DocumentFiles
    let blobs: [String: Data]
    /// The imported file on disk, kept so a test can compare the output with
    /// the bytes it was made from.
    let original: URL
}

private func annotatedDocument(
    marks: Data,
    sheet: CGSize = CGSize(width: 612, height: 792)
) throws -> AnnotatedFixture {
    let original = try blankPDF(pages: 1, size: sheet)
    let pdf = try Data(contentsOf: original)
    // One page, standing on page one of the imported file: `redir` present is
    // what says the page came out of the PDF rather than being added later.
    let content = Data(#"""
    {"formatVersion": 2, "cPages": {"pages": [
      {"id": "page-0", "redir": {"timestamp": "1:2", "value": 0}}
    ]}}
    """#.utf8)
    return AnnotatedFixture(
        index: DocumentFiles(files: [
            DocumentFile(hash: address(pdf), name: "doc-1.pdf", size: Int64(pdf.count)),
            DocumentFile(hash: address(content), name: "doc-1.content", size: Int64(content.count)),
            DocumentFile(hash: address(marks), name: "doc-1/page-0.rm", size: Int64(marks.count)),
        ]),
        blobs: [address(pdf): pdf, address(content): content, address(marks): marks],
        original: original
    )
}

private func annotated(_ fixture: AnnotatedFixture, allowOverlay: Bool) async throws -> URL {
    let output = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    try await AnnotatedPDFRenderer(blobs: FixtureBlobs(fixture.blobs)).renderPDF(
        documentID: "doc-1",
        index: fixture.index,
        to: output,
        allowOverlay: allowOverlay
    )
    return output
}

/// A page of marks: one long, broad stroke across the middle of the sheet.
///
/// Broad because the tests below weigh the whole page: a hairline is a
/// rounding error next to anything else on the sheet, and a comparison it
/// cannot move is a comparison that passes whatever happens.
private func markedPage() -> Data {
    makePage(
        tool: UInt32(PenTool.fineliner1.rawValue),
        color: UInt32(PenColor.black.rawValue),
        points: (0...20).map { StrokeSample(x: Float(-400 + $0 * 40), y: 600, width: 200) }
    )
}

/// The same page with an eraser drawn across the middle of that stroke.
///
/// Two blocks in one file, which is all a page with two strokes is: `makePage`
/// writes one block after the header and the service quartet, so the second
/// stroke is that same block again with its header taken off. The eraser is
/// second in the chain, and that is what makes it erase rather than be erased.
private func markedPageWithAnEraser() -> Data {
    let eraser = makePage(
        tool: UInt32(PenTool.eraser.rawValue),
        points: [
            StrokeSample(x: 0, y: 480, width: 400),
            StrokeSample(x: 0, y: 720, width: 400),
        ],
        item: (1, 2),
        left: (1, 1),
        service: false
    )
    return markedPage() + eraser.dropFirst(RMParser.header.utf8.count)
}

// The overlay exists because redrawing a document loses its links and its
// outline; it is allowed to exist because the page it appends is the page the
// redraw would have made. `allowOverlay` exists for that comparison, and this
// test makes it. One assertion is the point of this: whatever the two routes
// do next, they have to do it alike.
@Test("The appended marks and the redrawn ones are the same page")
func overlayAndRedrawDrawTheSamePage() async throws {
    let fixture = try annotatedDocument(marks: markedPage())
    let appended = try await annotated(fixture, allowOverlay: true)
    let redrawn = try await annotated(fixture, allowOverlay: false)
    defer {
        for url in [fixture.original, appended, redrawn] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // First that the two really are two routes and not one taken twice: the
    // appended file still opens with the imported document's own bytes, the
    // redrawn one is a fresh PDF written by Quartz.
    let source = try Data(contentsOf: fixture.original)
    #expect(try Data(contentsOf: appended).starts(with: source), "the overlay was not taken")
    #expect(try !Data(contentsOf: redrawn).starts(with: source), "the redraw was not taken")

    #expect(try boxOfPage(appended, page: 1) == (try boxOfPage(redrawn, page: 1)))
    let overlaid = try inkOfPage(appended, page: 1)
    let drawn = try inkOfPage(redrawn, page: 1)
    #expect(overlaid > 0, "a page with a stroke on it cannot be blank")
    // A few percent: the two lay the same ink down through different machinery
    // — PDF operators against CoreGraphics calls — so their antialiased edges
    // will never agree to the pixel. Anything past this is a difference in
    // what was drawn rather than in how it was rasterised.
    let apart = Double(abs(overlaid - drawn)) / Double(max(overlaid, drawn))
    #expect(apart < 0.05, "the two routes drew \(overlaid) and \(drawn) — \(Int(apart * 100))% apart")
}

// A redraw writes a fresh PDF, so the imported document's navigation has to be
// carried across on purpose: a web link and a link to another page on page one,
// and an outline entry pointing at page two.
@Test("Links and the outline survive a redraw")
func linksAndOutlineSurviveARedraw() async throws {
    let web = try #require(URL(string: "https://example.com/chapter"))
    let drawn = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: drawn))
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    context.beginPDFPage(nil)
    context.setURL(web as CFURL, for: CGRect(x: 72, y: 700, width: 200, height: 20))
    context.setDestination("chapter" as CFString, for: CGRect(x: 72, y: 600, width: 200, height: 20))
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.addDestination("chapter" as CFString, at: CGPoint(x: 72, y: 720))
    context.endPDFPage()
    let entry: [String: Any] = [
        kCGPDFOutlineTitle as String: "Chapter",
        kCGPDFOutlineDestination as String: 2,
    ]
    CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: [entry]] as CFDictionary)
    context.closePDF()

    let pdf = drawn as Data
    #expect(PDFDocument(data: pdf)?.outlineRoot?.numberOfChildren == 1, "the source has no outline")
    let original = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    try pdf.write(to: original)

    let marks = markedPage()
    let content = Data(#"""
    {"formatVersion": 2, "cPages": {"pages": [
      {"id": "page-0", "redir": {"timestamp": "1:2", "value": 0}},
      {"id": "page-1", "redir": {"timestamp": "1:3", "value": 1}}
    ]}}
    """#.utf8)
    let fixture = AnnotatedFixture(
        index: DocumentFiles(files: [
            DocumentFile(hash: address(pdf), name: "doc-1.pdf", size: Int64(pdf.count)),
            DocumentFile(hash: address(content), name: "doc-1.content", size: Int64(content.count)),
            DocumentFile(hash: address(marks), name: "doc-1/page-0.rm", size: Int64(marks.count)),
        ]),
        blobs: [address(pdf): pdf, address(content): content, address(marks): marks],
        original: original
    )
    let redrawn = try await annotated(fixture, allowOverlay: false)
    defer {
        for url in [original, redrawn] {
            try? FileManager.default.removeItem(at: url)
        }
    }
    #expect(try !Data(contentsOf: redrawn).starts(with: pdf), "the redraw was not taken")

    let output = try #require(PDFDocument(url: redrawn))
    #expect(output.pageCount == 2)
    let first = try #require(output.page(at: 0))
    let links = first.annotations.filter { $0.type == "Link" }
    let urls = links.compactMap { ($0.action as? PDFActionURL)?.url }
    #expect(urls == [web], "the web link did not survive")
    let targets = links.compactMap { link -> Int? in
        guard let page = (link.action as? PDFActionGoTo)?.destination.page ?? link.destination?.page else { return nil }
        return output.index(for: page)
    }
    #expect(targets == [1], "the link to page two did not survive")

    let outline = try #require(output.outlineRoot)
    #expect(outline.numberOfChildren == 1)
    let survived = try #require(outline.child(at: 0))
    #expect(survived.label == "Chapter")
    let page = try #require(survived.destination?.page)
    #expect(output.index(for: page) == 1, "the outline entry lost its page")
}

// Erasing applies to the tablet ink inside the imported overlay Form.
// The original PDF stays intact, and the visible result must match redraw.
@Test("A page somebody rubbed out agrees and preserves the original PDF")
func aPageWithAnEraserPreservesTheOriginalAndMatchesRedraw() async throws {
    let bytes = markedPageWithAnEraser()
    // The fixture first: a page whose second stroke is not the eraser would
    // make everything below pass for the wrong reason.
    let parsed = try RMParser.parsePage(bytes)
    #expect(parsed.strokes.map(\.tool) == [.fineliner1, .eraser])

    let fixture = try annotatedDocument(marks: bytes)
    let appended = try await annotated(fixture, allowOverlay: true)
    let redrawn = try await annotated(fixture, allowOverlay: false)
    let whole = try annotatedDocument(marks: markedPage())
    let untouched = try await annotated(whole, allowOverlay: false)
    defer {
        for url in [fixture.original, whole.original, appended, redrawn, untouched] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    let source = try Data(contentsOf: fixture.original)
    #expect(
        try Data(contentsOf: appended).starts(with: source),
        "the overlay must preserve the original PDF bytes even when ink is erased"
    )

    let overlaid = try inkOfPage(appended, page: 1)
    let drawn = try inkOfPage(redrawn, page: 1)
    let apart = Double(abs(overlaid - drawn)) / Double(max(overlaid, drawn))
    #expect(apart < 0.05, "the two routes drew \(overlaid) and \(drawn) — \(Int(apart * 100))% apart")

    // And the eraser took something off, or there would be nothing for the
    // agreement above to be about: a page that erased nothing would agree
    // whichever way it was drawn.
    //
    // Counted where the eraser went rather than over the whole sheet, so that
    // what is being asked is "is there a hole here" and not "is the page a
    // little lighter". The stroke sits 600 units below the top of a
    // 612 × 792 page — 190 pt down, so 602 pt up — and the eraser crosses it
    // as a band 100 units, near enough 32 pt, wide about the centre.
    let band = CGRect(x: 293, y: 585, width: 26, height: 34)
    let erased = try inkOfPage(redrawn, page: 1, within: band)
    let intact = try inkOfPage(untouched, page: 1, within: band)
    #expect(intact > 0, "the fixture's stroke has to cross the band it is checked in")
    #expect(
        Double(erased) < Double(intact) * 0.2,
        "the eraser has to leave a hole worth noticing: \(erased) of \(intact)"
    )
}

// MARK: - Giving up on a render, and what it leaves behind

private struct NotebookFixture {
    let index: DocumentFiles
    let blobs: [String: Data]
    /// The address of the page fetched last. Holding that one back is what
    /// puts a render in a known place: every page is in hand and none is drawn.
    let lastPage: String
}

private func notebookDocument(pages count: Int) -> NotebookFixture {
    var files: [DocumentFile] = []
    var blobs: [String: Data] = [:]
    var ids: [String] = []
    var last = ""
    for position in 0..<count {
        // Distinct bytes per page. The store is addressed by content, so two
        // identical pages would be one blob and the gate below could not tell
        // the last page from the first.
        let bytes = makePage(
            points: (0...60).map {
                StrokeSample(x: Float(-600 + $0 * 20), y: Float(200 + position * 5), width: 24)
            }
        )
        let id = String(format: "page-%03d", position)
        let hash = address(bytes)
        ids.append(id)
        blobs[hash] = bytes
        last = hash
        files.append(DocumentFile(hash: hash, name: "doc-1/\(id).rm", size: Int64(bytes.count)))
    }
    let listing = ids.map { #"{"id": "\#($0)"}"# }.joined(separator: ",")
    let content = Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(listing)]}}"#.utf8)
    blobs[address(content)] = content
    files.append(
        DocumentFile(hash: address(content), name: "doc-1.content", size: Int64(content.count))
    )
    return NotebookFixture(index: DocumentFiles(files: files), blobs: blobs, lastPage: last)
}

/// Where a render reads its last page, and so where a test can hold it: a
/// notebook's PDF, and an imported PDF's redraw, read every written page
/// twice — once to measure the document, and again as the drawing comes to
/// it.
enum LastPageRead: Sendable {
    /// The measuring read. Nothing is drawn yet, and no drawing task exists.
    case measuring
    /// The drawing's read. The drawing has begun, in a task of its own, and
    /// the last page cannot be on the sheet before this read returns.
    case drawing

    /// The reads of the last page that go by before the one held.
    var earlier: Int {
        switch self {
        case .measuring: 0
        case .drawing: 1
        }
    }
}

/// Counts the pages a render asks for — every read, the measuring and the
/// drawing's alike.
private actor Reads {
    private(set) var count = 0
    func add() { count += 1 }
}

/// What a cancelled render came to: what it ended with, how many page reads
/// it made, and whether it told the caller of unreadable pages.
private struct CancelledRender {
    let thrown: (any Error)?
    let reads: Int
    let unreadable: Bool
}

/// A render held at a read of its last page, cancelled there, and then let go.
///
/// The order is what makes this deterministic rather than lucky: the last
/// page cannot be handed over until the cancel is on record, and the render
/// cannot be finished without it. Held at the `.measuring` read, the cancel
/// is there before any drawing task exists, and no drawing may be begun for
/// it; held at the `.drawing` read, it has to cross into the detached task
/// the drawing runs in, and stop it between two pages.
private func cancelledRender(
    pages: Int,
    at read: LastPageRead,
    _ body: @escaping @Sendable (NotebookRenderer, DocumentFiles, _ onUnreadable: @escaping @Sendable (Int) -> Void)
        async throws -> Void
) async throws -> CancelledRender {
    let fixture = notebookDocument(pages: pages)
    let gate = Gate(wavingThrough: read.earlier)
    let reads = Reads()
    let pageHashes = Set(fixture.index.files.filter { $0.fileExtension == "rm" }.map(\.hash))
    let blobs = FixtureBlobs(fixture.blobs) { hash in
        if pageHashes.contains(hash) { await reads.add() }
        if hash == fixture.lastPage { await gate.stopHere() }
    }
    let unreadable = Flag()
    let render = Task {
        try await body(NotebookRenderer(blobs: blobs), fixture.index) { _ in unreadable.raise() }
    }
    await gate.waitForArrival()
    render.cancel()
    await gate.open()

    let thrown: (any Error)?
    do {
        try await render.value
        thrown = nil
    } catch {
        thrown = error
    }
    return CancelledRender(thrown: thrown, reads: await reads.count, unreadable: unreadable.isRaised)
}

/// A flag raised from any task.
private final class Flag: Sendable {
    private let state = Mutex(false)
    func raise() { state.withLock { $0 = true } }
    var isRaised: Bool { state.withLock { $0 } }
}

// `RenderWork.detached` puts the drawing in a detached task, and a detached
// task inherits nothing — cancellation included. Without the handler that
// forwards it, a render the caller has already given up on would run to its
// last page and the caller would stay parked until it did. Nothing would say
// so: the document would come out correct, only far too late.
@Test(
    "A render the caller has given up on stops instead of drawing to the end",
    arguments: [LastPageRead.measuring, .drawing]
)
func aCancelledRenderStops(at read: LastPageRead) async throws {
    let outcome = try await cancelledRender(pages: 40, at: read) { renderer, index, onUnreadable in
        _ = try await renderer.renderPDF(documentID: "doc-1", index: index, onUnreadable: onUnreadable)
    }

    #expect(outcome.thrown is CancellationError, "got \(String(describing: outcome.thrown))")
    // A page whose parse was cut short is not a page that would not parse.
    #expect(!outcome.unreadable, "a cancelled read was told to the caller as an unreadable page")
}

// Cancelled while it measures, a render never begins to draw. The drawing is
// handed to a task of its own, and the handler that forwards the cancel to
// it is installed only once that task exists — a task that may already be
// running. On a loaded machine the caller's thread can be put aside in that
// moment, and a drawing of forty small pages finishes inside it unasked: the
// render came back whole, and `nil` stood where `CancellationError` belonged.
// So the drawing must not be begun at all, and the proof is in the reads:
// every page read once, to be measured, and none read again to be drawn.
@Test("A render given up on while it measures never begins to draw")
func aRenderCancelledWhileMeasuringDrawsNothing() async throws {
    let pages = 40
    let outcome = try await cancelledRender(pages: pages, at: .measuring) { renderer, index, _ in
        _ = try await renderer.renderPDF(documentID: "doc-1", index: index)
    }

    #expect(outcome.thrown is CancellationError, "got \(String(describing: outcome.thrown))")
    #expect(outcome.reads == pages, "the drawing read pages again after the cancel: \(outcome.reads) reads")
}

// The other half of the race above, without the race: work handed off for a
// caller that is cancelled already is refused before it exists. Whether a task
// started too early would have finished unasked is the scheduler's business;
// whether it is started at all is ours.
@Test("Work handed off for a caller already cancelled is never started")
func detachedWorkForACancelledCallerNeverStarts() async throws {
    let started = Flag()
    let caller = Task { () -> [(any Error)?] in
        withUnsafeCurrentTask { $0?.cancel() }
        var thrown: [(any Error)?] = []
        do {
            _ = try await RenderWork.detached {
                started.raise()
                return 1
            }
            thrown.append(nil)
        } catch {
            thrown.append(error)
        }
        do {
            _ = try await RenderWork.detachedWaiting {
                started.raise()
                return 2
            }
            thrown.append(nil)
        } catch {
            thrown.append(error)
        }
        return thrown
    }

    for error in await caller.value {
        #expect(error is CancellationError, "got \(String(describing: error))")
    }
    #expect(!started.isRaised, "the work ran for a caller that had already given up")
}

@Test(
    "A render that stops leaves no half-written file where the caller asked for one",
    arguments: [LastPageRead.measuring, .drawing]
)
func aCancelledFileRenderLeavesNothing(at read: LastPageRead) async throws {
    let output = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }

    let outcome = try await cancelledRender(pages: 40, at: read) { renderer, index, onUnreadable in
        try await renderer.renderPDF(documentID: "doc-1", index: index, to: output, onUnreadable: onUnreadable)
    }

    #expect(outcome.thrown is CancellationError, "got \(String(describing: outcome.thrown))")
    #expect(!outcome.unreadable, "a cancelled read was told to the caller as an unreadable page")
    // A truncated PDF at the path the caller asked for is worse than nothing:
    // it opens, and it is wrong.
    #expect(
        !FileManager.default.fileExists(atPath: output.path),
        "a stopped render left a file behind"
    )
}

// The bitmaps read each page once — `parsed` keeps them — so the measuring
// read is the only one there is to hold.
@Test("A notebook's bitmaps given up on stop as its PDF does")
func aCancelledImageRenderStops() async throws {
    let outcome = try await cancelledRender(pages: 40, at: .measuring) { renderer, index, onUnreadable in
        _ = try await renderer.renderImages(documentID: "doc-1", index: index, onUnreadable: onUnreadable)
    }

    #expect(outcome.thrown is CancellationError, "got \(String(describing: outcome.thrown))")
    #expect(!outcome.unreadable, "a cancelled read was told to the caller as an unreadable page")
}

/// An imported PDF of `count` pages with marks on every one, and the address
/// of the page fetched last — the same handle `notebookDocument` keeps, for the
/// same reason: holding that page back puts the render in a known place.
private func annotatedDocument(pages count: Int) throws -> (fixture: AnnotatedFixture, lastPage: String) {
    let original = try blankPDF(pages: count, size: CGSize(width: 612, height: 792))
    let pdf = try Data(contentsOf: original)
    var files = [DocumentFile(hash: address(pdf), name: "doc-1.pdf", size: Int64(pdf.count))]
    var blobs = [address(pdf): pdf]
    var listing: [String] = []
    var last = ""
    for position in 0..<count {
        // Distinct bytes per page, or the content-addressed store would make
        // one blob of them all and the last page could not be told apart.
        let bytes = makePage(
            points: (0...20).map {
                StrokeSample(x: Float(-400 + $0 * 40), y: Float(600 + position * 5), width: 200)
            }
        )
        let id = String(format: "page-%03d", position)
        let hash = address(bytes)
        blobs[hash] = bytes
        last = hash
        files.append(DocumentFile(hash: hash, name: "doc-1/\(id).rm", size: Int64(bytes.count)))
        listing.append(#"{"id": "\#(id)", "redir": {"timestamp": "1:2", "value": \#(position)}}"#)
    }
    let content = Data(
        #"{"formatVersion": 2, "cPages": {"pages": [\#(listing.joined(separator: ","))]}}"#.utf8
    )
    blobs[address(content)] = content
    files.append(DocumentFile(hash: address(content), name: "doc-1.content", size: Int64(content.count)))
    return (AnnotatedFixture(index: DocumentFiles(files: files), blobs: blobs, original: original), last)
}

// The same promise from the other renderer. The redraw of an imported PDF makes
// its context and then asks about cancellation page by page, and a
// `CancellationError` before `closePDF` must not leave a half-written file
// where the caller asked for the whole one. Held at either read of the last
// page's marks: the measuring one, before any drawing exists, and the
// drawing's, with the redraw under way in a task of its own.
@Test(
    "A stopped redraw of an imported PDF leaves no half-written file either",
    arguments: [LastPageRead.measuring, .drawing]
)
func aCancelledAnnotatedRenderLeavesNothing(at read: LastPageRead) async throws {
    let (fixture, lastPage) = try annotatedDocument(pages: 40)
    let output = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer {
        try? FileManager.default.removeItem(at: fixture.original)
        try? FileManager.default.removeItem(at: output)
    }

    let gate = Gate(wavingThrough: read.earlier)
    let blobs = FixtureBlobs(fixture.blobs) { hash in
        if hash == lastPage { await gate.stopHere() }
    }
    let render = Task {
        // The overlay switched off: it is the redraw that writes a file of its
        // own page by page, and the redraw that has to clean up after itself.
        try await AnnotatedPDFRenderer(blobs: blobs).renderPDF(
            documentID: "doc-1",
            index: fixture.index,
            to: output,
            allowOverlay: false
        )
    }
    await gate.waitForArrival()
    render.cancel()
    await gate.open()

    let thrown: (any Error)?
    do {
        try await render.value
        thrown = nil
    } catch {
        thrown = error
    }

    #expect(thrown is CancellationError, "got \(String(describing: thrown))")
    #expect(
        !FileManager.default.fileExists(atPath: output.path),
        "a stopped render left a file behind"
    )
}

// MARK: - The same notebook, handed back and written out

// The file overload exists so that a big notebook does not stand twice in a
// process that may be killed for memory. It is a second entry point into one
// piece of work, and a second entry point is a second thing that can drift.
@Test("A notebook written to a file is the document the other overload hands back")
func theFileAndTheDataRoutesDrawTheSameNotebook() async throws {
    let fixture = notebookDocument(pages: 3)
    let renderer = NotebookRenderer(blobs: FixtureBlobs(fixture.blobs))
    let output = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }

    let held = try await renderer.renderPDF(documentID: "doc-1", index: fixture.index)
    try await renderer.renderPDF(documentID: "doc-1", index: fixture.index, to: output)

    let onDisk = try #require(CGDataProvider(url: output as CFURL).flatMap(CGPDFDocument.init))
    let inMemory = try #require(CGDataProvider(data: held as CFData).flatMap(CGPDFDocument.init))

    #expect(onDisk.numberOfPages == 3, "the file has to open as the notebook it was")
    #expect(onDisk.numberOfPages == inMemory.numberOfPages)
    let boxes = (1...onDisk.numberOfPages).map {
        (onDisk.page(at: $0)?.getBoxRect(.mediaBox), inMemory.page(at: $0)?.getBoxRect(.mediaBox))
    }
    for (position, pair) in boxes.enumerated() {
        #expect(pair.0 == pair.1, "page \(position + 1) came out \(String(describing: pair))")
    }
}

// MARK: - Where the marker went on an imported page

/// The coloured pixels of one page of a PDF, as fractions of its box from
/// the top left — the corner a band counts from. Colour rather than
/// darkness: the imported sheet's own drawing is grey and the marker is
/// not, so this finds the band and nothing else.
private func colourBoxOfPage(_ url: URL, page: Int) throws -> PageBox? {
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let pdfPage = try #require(document.page(at: page))
    let box = pdfPage.getBoxRect(.mediaBox)
    let width = Int(box.width), height = Int(box.height)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(pdfPage)
    let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    var left = width, right = -1, top = height, bottom = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            guard max(red, max(green, blue)) - min(red, min(green, blue)) > 40 else { continue }
            left = min(left, x); right = max(right, x)
            top = min(top, y); bottom = max(bottom, y)
        }
    }
    guard right >= 0 else { return nil }
    return PageBox(
        x0: Double(left) / Double(width), y0: Double(top) / Double(height),
        x1: Double(right + 1) / Double(width), y1: Double(bottom + 1) / Double(height)
    )
}

@Test("A band of a marked PDF lands on the pixels of the flattened page")
func bandOfAnImportedPageLandsOnItsPixels() async throws {
    // Out past the left edge of the sheet on purpose: that is what grows
    // the page's box, and a band stated in fractions of the plain sheet
    // instead would sit beside its own pixels on exactly such a page.
    let marks = makePage(
        tool: UInt32(PenTool.highlighter2.rawValue),
        color: UInt32(PenColor.yellow.rawValue),
        points: (0...10).map { StrokeSample(x: Float(-1200 + $0 * 100), y: 600, width: 120) }
    )
    let fixture = try annotatedDocument(marks: marks)
    defer { try? FileManager.default.removeItem(at: fixture.original) }

    let marked = try await AnnotatedPDFRenderer(blobs: FixtureBlobs(fixture.blobs))
        .marks(documentID: "doc-1", index: fixture.index)
    #expect(marked.count == 1)
    let band = try #require(marked.first?.bands.first)

    // Against the page the recogniser is handed: the flatten, rasterised by
    // its media box. Both roads out of the renderer grow the same box, so
    // the overlay is the one to check — it is the road a document like this
    // one actually takes.
    let output = try await annotated(fixture, allowOverlay: true)
    defer { try? FileManager.default.removeItem(at: output) }
    let drawn = try #require(try colourBoxOfPage(output, page: 1))
    let apart = max(
        max(abs(band.box.x0 - drawn.x0), abs(band.box.x1 - drawn.x1)),
        max(abs(band.box.y0 - drawn.y0), abs(band.box.y1 - drawn.y1))
    )
    #expect(apart < 0.01, "band \(band.box) against the pixels \(drawn)")
}
