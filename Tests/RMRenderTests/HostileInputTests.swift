// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Foundation
import RMLines
@testable import RMRender
import Testing

// A `.content` is a file anybody can write, and a host may draw whatever file
// it is handed. These are the page lists nothing on a tablet writes: a
// `redir` of `Int.max`, a page named twice, a page file nobody lists, a
// document longer than its host can afford. None of them may end the
// process, and none may carry the output past the cap a host asked for.

// MARK: - Fixtures

/// What happened, in the order it happened: the names of the blobs asked
/// for, and whatever a callback wrote beside them. Behind a lock, because
/// pages are fetched by a fan-out.
private final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    var all: [String] { lock.withLock { entries } }

    /// The page files asked for, by page id.
    var pagesFetched: [String] {
        all.filter { $0.hasSuffix(".rm") }.map { String($0.dropFirst("doc/".count).dropLast(".rm".count)) }
    }
}

private struct Blobs: PageBlobs {
    let blobs: [String: Data]
    var journal: Journal?

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        journal?.append(name)
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
        return BlobFile(url: url, isTemporary: true)
    }
}

private func address(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// A document out of named files: the index and the store behind it. A name
/// may come twice — that is one of the cases.
private func document(
    _ files: [(name: String, bytes: Data)],
    journal: Journal? = nil
) -> (index: DocumentFiles, blobs: Blobs) {
    var store: [String: Data] = [:]
    let entries = files.map { file in
        store[address(file.bytes)] = file.bytes
        return DocumentFile(hash: address(file.bytes), name: file.name, size: Int64(file.bytes.count))
    }
    return (DocumentFiles(files: entries), Blobs(blobs: store, journal: journal))
}

/// A page with ink on it, its bytes distinct per `seed` so the
/// content-addressed store keeps every page apart.
private func inkedPage(_ seed: Int) -> Data {
    makePage(points: (0...10).map { StrokeSample(x: Float(-300 + $0 * 60), y: Float(300 + seed * 7), width: 24) })
}

/// A `cPages` record. `redir` is written out as given, so a test can put any
/// JSON there — a number past what an `Int` holds, a fraction, a string.
private func record(_ id: String, idx: String? = nil, redir: String? = nil) -> String {
    var fields = [#""id": "\#(id)""#]
    if let idx { fields.append(#""idx": {"timestamp": "1:2", "value": "\#(idx)"}"#) }
    if let redir { fields.append(#""redir": {"timestamp": "1:2", "value": \#(redir)}"#) }
    return "{\(fields.joined(separator: ", "))}"
}

private func cPages(_ records: [String]) -> Data {
    Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(records.joined(separator: ", "))]}}"#.utf8)
}

/// An imported PDF whose pages are told apart by their width: page *n*
/// (from zero) is `300 + 10n` points wide. A page of the output standing on
/// page *n* has that width; one standing on nothing has the tablet's sheet.
private func originalPDF(pages: Int) throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for page in 0..<pages {
        var media = CGRect(x: 0, y: 0, width: 300 + 10 * page, height: 400)
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)]
        context.beginPDFPage(info as CFDictionary)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 20, y: 20, width: 30, height: 30))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// The width of every page of a PDF, rounded to the point.
private func widths(_ pdf: CGPDFDocument) -> [Int] {
    (0..<pdf.numberOfPages).compactMap {
        pdf.page(at: $0 + 1).map { Int($0.getBoxRect(.mediaBox).width.rounded()) }
    }
}

private func open(_ data: Data) throws -> CGPDFDocument {
    try #require(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init))
}

private func open(_ url: URL) throws -> CGPDFDocument {
    try #require(CGDataProvider(url: url as CFURL).flatMap(CGPDFDocument.init))
}

/// The width of a page standing on no original: the tablet's sheet in points.
private let blankWidth = Int(AnnotationGeometry.sheet(forScene: PageRenderer.defaultPageSize).width.rounded())

/// Counts what a callback is told, across the concurrency boundary a
/// `@Sendable` closure stands behind.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.withLock { values.append(value) }
    }

    var all: [Int] { lock.withLock { values } }
}

private func annotated(
    _ original: Data,
    content: Data?,
    pages: [(id: String, bytes: Data)] = [],
    maximumPages: Int? = nil,
    allowOverlay: Bool = true,
    pageCount: Recorded? = nil
) async throws -> CGPDFDocument {
    var files: [(name: String, bytes: Data)] = [("doc.pdf", original)]
    if let content { files.append(("doc.content", content)) }
    files += pages.map { ("doc/\($0.id).rm", $0.bytes) }
    let (index, blobs) = document(files)
    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    try await AnnotatedPDFRenderer(blobs: blobs).renderPDF(
        documentID: "doc",
        index: index,
        to: output,
        allowOverlay: allowOverlay,
        maximumPages: maximumPages,
        onPageCount: { _, document in pageCount?.append(document) }
    )
    // Read into memory before the file goes: the document is checked after.
    return try open(try Data(contentsOf: output))
}

// MARK: - Redirections a file cannot honour

private let hostileRedirs = [
    "9223372036854775807", // Int.max: plus one is a trap
    "-9223372036854775808", // Int.min
    "-1",
    "3", // one past the end of a three-page original
    "9223372036854775808", // past what an Int holds: not a number of ours at all
    "1.5",
    #""1""#,
    "null",
]

@Test("A redir the original cannot honour stands on no page, in either form of .content")
func hostileRedirectionsAreDropped() throws {
    let records = hostileRedirs.enumerated().map { record("p\($0.offset)", redir: $0.element) }
        + [record("good", redir: "1"), record("added")]
    let modern = try PageOrder.layout(from: cPages(records))
    // Read first: the page list survives every bad number in it — the order
    // and the good page included — instead of failing to decode whole.
    #expect(modern.pages.map(\.id) == hostileRedirs.indices.map { "p\($0)" } + ["good", "added"])
    let checked = PageOrder.checked(modern.pages, originalPages: 3)
    #expect(checked.map(\.redir) == Array(repeating: nil, count: hostileRedirs.count) + [1, nil])

    let flat = Data(#"""
    {"pages": ["a", "b", "c", "d", "e", "f"],
     "redirectionPageMap": [9223372036854775807, -9223372036854775808, -1, 3, 1e30, 2]}
    """#.utf8)
    let legacy = try PageOrder.layout(from: flat)
    #expect(legacy.pages.map(\.id) == ["a", "b", "c", "d", "e", "f"])
    #expect(PageOrder.checked(legacy.pages, originalPages: 3).map(\.redir) == [nil, nil, nil, nil, nil, 2])
}

@Test("A page whose redir is out of range is drawn on blank paper, not trapped on")
func hostileRedirectionsRenderAsBlankSheets() async throws {
    let original = try originalPDF(pages: 3)
    let records = hostileRedirs.enumerated().map { record("p\($0.offset)", idx: "a\($0.offset)", redir: $0.element) }
        + [record("good", idx: "b", redir: "1")]
    // Marks on two of the hostile pages and on the good one, so both the
    // pages with ink and those without go through the lookup.
    let pages = [("p0", inkedPage(0)), ("p3", inkedPage(3)), ("good", inkedPage(9))]

    for allowOverlay in [true, false] {
        let pdf = try await annotated(original, content: cPages(records), pages: pages, allowOverlay: allowOverlay)
        #expect(pdf.numberOfPages == hostileRedirs.count + 1)
        let drawn = widths(pdf)
        // Every hostile page on the tablet's sheet, and the good one on page
        // two of the original (310 wide), or on more where its ink grew it.
        #expect(drawn.prefix(hostileRedirs.count).allSatisfy { $0 >= blankWidth })
        #expect(drawn.last.map { $0 >= 310 && $0 < blankWidth } == true, "\(drawn)")
    }
}

@Test("The flat form with an Int.max in its map renders as well")
func hostileFlatMapRenders() async throws {
    let original = try originalPDF(pages: 3)
    let content = Data(#"""
    {"pages": ["a", "b", "c", "d"],
     "redirectionPageMap": [9223372036854775807, -9223372036854775808, 3, 2]}
    """#.utf8)
    let pdf = try await annotated(original, content: content)
    #expect(widths(pdf) == [blankWidth, blankWidth, blankWidth, 320])
}

@Test("The page lookup itself refuses a number the file has no page for")
func originalPageIsChecked() throws {
    let pdf = try open(try originalPDF(pages: 2))
    for redir in [Int.max, Int.min, -1, 2] {
        #expect(AnnotatedPDFRenderer.originalPage(redir, in: pdf) == nil, "\(redir)")
    }
    #expect(AnnotatedPDFRenderer.originalPage(nil, in: pdf) == nil)
    #expect(AnnotatedPDFRenderer.originalPage(1, in: pdf).map { Int($0.getBoxRect(.mediaBox).width) } == 310)
}

@Test("A notebook with hostile redirs reads as a notebook and keeps none below zero")
func notebookIgnoresHostileRedirections() async throws {
    let content = cPages([
        record("p0", idx: "a", redir: "9223372036854775807"),
        record("p1", idx: "b", redir: "-9223372036854775808"),
    ])
    let (index, blobs) = document([("doc.content", content), ("doc/p0.rm", inkedPage(0)), ("doc/p1.rm", inkedPage(1))])
    let renderer = NotebookRenderer(blobs: blobs)
    #expect(await renderer.orderedPages(index: index).map(\.redir) == [Int.max, nil])
    #expect(try open(try await renderer.renderPDF(documentID: "doc", index: index)).numberOfPages == 2)
}

// MARK: - A page named twice

@Test("A page .content names twice is one page, where it first stands")
func duplicateIDsAreOnePage() throws {
    let modern = try PageOrder.layout(from: cPages([
        record("a", idx: "a1"), record("b", idx: "a2"), record("a", idx: "a3"), record("c", idx: "a4"),
    ]))
    #expect(modern.pages.map(\.id) == ["a", "b", "c"])

    let flat = try PageOrder.layout(from: Data(#"{"pages": ["x", "y", "x"], "redirectionPageMap": [0, 1, 2]}"#.utf8))
    #expect(flat.pages.map(\.id) == ["x", "y"])
    // The number of the place a page first stood in, not of a later one.
    #expect(flat.pages.map(\.redir) == [0, 1])
}

@Test("A notebook listing one page ten thousand times draws it once")
func duplicateIDsDoNotMultiplyANotebook() async throws {
    let content = cPages(Array(repeating: record("p0"), count: 10_000) + [record("p1")])
    let (index, blobs) = document([("doc.content", content), ("doc/p0.rm", inkedPage(0)), ("doc/p1.rm", inkedPage(1))])
    let pdf = try open(try await NotebookRenderer(blobs: blobs).renderPDF(documentID: "doc", index: index))
    #expect(pdf.numberOfPages == 2)
}

@Test("An annotated document listing a page twice draws it once")
func duplicateIDsDoNotMultiplyAnAnnotatedDocument() async throws {
    let original = try originalPDF(pages: 2)
    let content = cPages([
        record("p0", idx: "a", redir: "0"), record("p1", idx: "b", redir: "1"), record("p0", idx: "c", redir: "0"),
    ])
    let pdf = try await annotated(original, content: content, pages: [("p0", inkedPage(0))])
    #expect(widths(pdf).count == 2)
}

@Test("Two index records of one page file are one page")
func duplicateIndexRecordsAreOnePage() {
    let entry = DocumentFile(hash: "h", name: "doc/p1.rm", size: 1)
    let order = NotebookRenderer.order(
        [PageOrder.Page(id: "p0", template: nil, redir: nil)],
        entries: [DocumentFile(hash: "g", name: "doc/p0.rm", size: 1), entry, entry]
    )
    #expect(order.map { $0.entry?.fileBaseName } == ["p0", "p1"])
    #expect(NotebookRenderer.unique([entry, entry]).count == 1)
}

// MARK: - Pages nobody lists

private func notebookWithOrphans() -> (index: DocumentFiles, blobs: Blobs) {
    document([
        ("doc.content", cPages([record("listed")])),
        ("doc/listed.rm", inkedPage(0)),
        ("doc/orphan-a.rm", inkedPage(1)),
        ("doc/orphan-b.rm", inkedPage(2)),
    ])
}

@Test("Unlisted page files follow the listed ones, unless the host says otherwise")
func unlistedPagesAreOptional() async throws {
    let (index, blobs) = notebookWithOrphans()
    let renderer = NotebookRenderer(blobs: blobs)

    let all = try open(try await renderer.renderPDF(documentID: "doc", index: index))
    #expect(all.numberOfPages == 3)
    #expect(await renderer.orderedPages(index: index).map { $0.entry?.fileBaseName } == ["listed", "orphan-a", "orphan-b"])

    let listed = try open(try await renderer.renderPDF(documentID: "doc", index: index, includesUnlistedPages: false))
    #expect(listed.numberOfPages == 1)
    let parsed = try await renderer.parsed(documentID: "doc", index: index, includesUnlistedPages: false)
    #expect(parsed.pageIDs == ["listed"])
}

@Test("Without a page list every page file is the document, whatever the option says")
func noPageListMeansNothingIsUnlisted() async throws {
    let (index, blobs) = document([("doc/a.rm", inkedPage(0)), ("doc/b.rm", inkedPage(1))])
    let pdf = try open(
        try await NotebookRenderer(blobs: blobs).renderPDF(documentID: "doc", index: index, includesUnlistedPages: false)
    )
    #expect(pdf.numberOfPages == 2)
}

// MARK: - The cap

private func longNotebook(pages count: Int) -> (index: DocumentFiles, blobs: Blobs) {
    let ids = (0..<count).map { String(format: "p%03d", $0) }
    return document(
        [("doc.content", cPages(ids.map { record($0) }))] + ids.enumerated().map { ("doc/\($1).rm", inkedPage($0)) }
    )
}

@Test("A notebook cut to a cap comes out at the cap, and says how long it was")
func notebookIsCapped() async throws {
    let (index, blobs) = longNotebook(pages: 7)
    let renderer = NotebookRenderer(blobs: blobs)

    let count = Recorded()
    let data = try await renderer.renderPDF(documentID: "doc", index: index, maximumPages: 3, onPageCount: { _, document in count.append(document) })
    #expect(try open(data).numberOfPages == 3)
    #expect(count.all == [7])

    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    try await renderer.renderPDF(documentID: "doc", index: index, to: output, maximumPages: 3)
    #expect(try open(output).numberOfPages == 3)

    let images = try await renderer.renderImages(documentID: "doc", index: index, maximumPages: 2)
    #expect(images.count == 2)

    let parsed = try await renderer.parsed(documentID: "doc", index: index, maximumPages: 4)
    #expect(parsed.pages.count == 4)
    #expect(parsed.documentPageCount == 7)
    #expect(parsed.pageIDs == ["p000", "p001", "p002", "p003"])

    // A cap the document does not reach changes nothing; one below one is one.
    #expect(try open(try await renderer.renderPDF(documentID: "doc", index: index, maximumPages: 50)).numberOfPages == 7)
    #expect(try open(try await renderer.renderPDF(documentID: "doc", index: index, maximumPages: 0)).numberOfPages == 1)
    #expect(try open(try await renderer.renderPDF(documentID: "doc", index: index, maximumPages: -5)).numberOfPages == 1)
}

@Test("The cap is applied after the orphans are appended, so they cannot carry a notebook past it")
func capCountsOrphans() async throws {
    let (index, blobs) = notebookWithOrphans()
    let renderer = NotebookRenderer(blobs: blobs)
    let count = Recorded()
    let pdf = try open(
        try await renderer.renderPDF(
            documentID: "doc", index: index, maximumPages: 2, onPageCount: { _, document in count.append(document) }
        )
    )
    #expect(pdf.numberOfPages == 2)
    #expect(count.all == [3])
    #expect(await renderer.orderedPages(index: index, maximumPages: 2).map { $0.entry?.fileBaseName } == ["listed", "orphan-a"])
}

@Test("An annotated document cut to a cap comes out at the cap")
func annotatedIsCapped() async throws {
    let original = try originalPDF(pages: 5)
    let content = cPages((0..<5).map { record("p\($0)", idx: "a\($0)", redir: "\($0)") })
    let marks = [("p0", inkedPage(0)), ("p4", inkedPage(4))]

    for allowOverlay in [true, false] {
        let count = Recorded()
        let pdf = try await annotated(
            original, content: content, pages: marks, maximumPages: 2, allowOverlay: allowOverlay, pageCount: count
        )
        #expect(pdf.numberOfPages == 2)
        #expect(widths(pdf).last == 310)
        #expect(count.all == [5])
    }

    // No marks at all is the case the overlay hands back as the original
    // untouched — which would be all five pages. The cap has to win.
    let bare = try await annotated(original, content: content, maximumPages: 3)
    #expect(widths(bare) == [300, 310, 320])

    // `.content` that lists nothing is the original page for page — cut too.
    let count = Recorded()
    let unlisted = try await annotated(original, content: nil, maximumPages: 2, pageCount: count)
    #expect(widths(unlisted) == [300, 310])
    #expect(count.all == [5])
}

@Test("The marks of an annotated document are cut where its render is")
func annotatedMarksAreCapped() async throws {
    let original = try originalPDF(pages: 4)
    let content = cPages((0..<4).map { record("p\($0)", idx: "a\($0)", redir: "\($0)") })
    let (index, blobs) = document([("doc.pdf", original), ("doc.content", content), ("doc/p0.rm", inkedPage(0))])
    let renderer = AnnotatedPDFRenderer(blobs: blobs)
    #expect(try await renderer.marks(documentID: "doc", index: index).count == 4)
    #expect(try await renderer.marks(documentID: "doc", index: index, maximumPages: 2).map(\.pageID) == ["p0", "p1"])
}

// MARK: - Sizes a file can state

/// A page with one stroke written `depth` units below the top of the sheet.
private func pageWithInk(at depth: Float, template: String? = nil) -> RMPage {
    RMPage(
        strokes: [
            Stroke(
                tool: .fineliner1,
                color: .black,
                thicknessScale: 1,
                points: [
                    StrokePoint(x: 0, y: 100, width: 8, pressure: 100),
                    StrokePoint(x: 10, y: depth, width: 8, pressure: 100),
                ]
            ),
        ],
        skippedBlocks: 0,
        templateName: template
    )
}

@Test("A declared sheet no page could have is a sheet not declared")
func absurdDeclaredSizesAreIgnored() throws {
    func declared(_ width: String, _ height: String) throws -> CGSize? {
        try PageOrder.layout(from: Data(#"""
        {"customZoomPageWidth": \#(width), "customZoomPageHeight": \#(height), "pages": ["p0"]}
        """#.utf8)).pageSize
    }
    #expect(try declared("1620", "2160") == CGSize(width: 1620, height: 2160))
    #expect(try declared("1e300", "2160") == nil)
    #expect(try declared("1e19", "1e19") == nil)
    #expect(try declared("-5", "2160") == nil)
    #expect(PageRenderer.plausibleCanvas(CGSize(width: CGFloat.nan, height: 10)) == nil)
    #expect(PageRenderer.plausibleCanvas(CGSize(width: CGFloat.infinity, height: 10)) == nil)
    #expect(PageRenderer.plausibleCanvas(nil) == nil)
}

// `1e19` passes a bare `> 0` check and would reach `Int(pageSize.width)` in a
// log line
// — evaluated only when a host has a sink installed, which every host does.
@Test("A notebook declaring a sheet of 1e19 units renders on the default sheet")
func notebookWithAbsurdSheetRenders() async throws {
    RMRenderLog.install { _, _, message in _ = message.count }
    defer { RMRenderLog.silence() }
    _ = FixtureTemplates.installed
    let content = Data(#"""
    {"customZoomPageWidth": 1e19, "customZoomPageHeight": 1e300,
     "cPages": {"pages": [{"id": "p0", "template": {"timestamp": "1:2", "value": "Fixture Dots"}}]}}
    """#.utf8)
    let (index, blobs) = document([("doc.content", content), ("doc/p0.rm", inkedPage(0))])
    let renderer = NotebookRenderer(blobs: blobs)
    let pdf = try open(try await renderer.renderPDF(documentID: "doc", index: index, paper: .tablet))
    #expect(pdf.numberOfPages == 1)
    #expect(await renderer.pageGeometry(index: index, owner: nil).pageSize == PageRenderer.defaultPageSize)
}

@Test("Ink a long way off the sheet is refused as a bitmap, not trapped on")
func farInkIsNotABitmap() throws {
    for depth: Float in [1e30, -1e30, 3e38] {
        #expect(throws: RenderError.bitmapContextUnavailable) {
            _ = try PageRenderer.image(page: pageWithInk(at: depth))
        }
    }
    // A page that only runs a little long is still drawn.
    let long = try PageRenderer.image(page: pageWithInk(at: 4000))
    #expect(long.height > Int(PageRenderer.defaultPageSize.height))
}

@Test("A grid under ink a billion units down is ruled to a fence, not to the ink", .timeLimit(.minutes(1)))
func farInkDoesNotRuleForever() throws {
    _ = FixtureTemplates.installed
    let page = pageWithInk(at: 1e9, template: "Fixture Dots")
    let pdf = try open(try PageRenderer.pdf(pages: [page], paper: .tablet))
    #expect(pdf.numberOfPages == 1)
}

// MARK: - Review follow-ups

@Test("Pages past the cap are never fetched, orphans included, and the count comes first")
func pagesPastTheCapAreNotFetched() async throws {
    let journal = Journal()
    let ids = (0..<6).map { "p\($0)" }
    let (index, blobs) = document(
        [("doc.content", cPages(ids.prefix(4).map { record($0) }))]
            + ids.enumerated().map { ("doc/\($1).rm", inkedPage($0)) },
        journal: journal
    )
    _ = try await NotebookRenderer(blobs: blobs).renderPDF(
        documentID: "doc", index: index, maximumPages: 2,
        onPageCount: { drawn, document in journal.append("count \(drawn) of \(document)") }
    )
    #expect(Set(journal.pagesFetched) == ["p0", "p1"])
    // Told before a single page was asked for: the count is worked out from
    // `.content` and the index alone.
    let first = try #require(journal.all.firstIndex { $0.hasSuffix(".rm") })
    #expect(journal.all.firstIndex(of: "count 2 of 6").map { $0 < first } == true, "\(journal.all)")

    // The orphans are past the cut too: listed pages fill it.
    let orphans = Journal()
    let (orphanIndex, orphanBlobs) = document(
        [("doc.content", cPages([record("listed")])), ("doc/listed.rm", inkedPage(0)),
         ("doc/orphan-a.rm", inkedPage(1)), ("doc/orphan-b.rm", inkedPage(2))],
        journal: orphans
    )
    _ = try await NotebookRenderer(blobs: orphanBlobs).parsed(documentID: "doc", index: orphanIndex, maximumPages: 2)
    #expect(Set(orphans.pagesFetched) == ["listed", "orphan-a"])
}

@Test("An annotated document past its cap fetches no marks past it, in the render or in marks")
func annotatedMarksPastTheCapAreNotFetched() async throws {
    let original = try originalPDF(pages: 4)
    let content = cPages((0..<4).map { record("p\($0)", idx: "a\($0)", redir: "\($0)") })
    let files: [(name: String, bytes: Data)] = [("doc.pdf", original), ("doc.content", content)]
        + (0..<4).map { ("doc/p\($0).rm", inkedPage($0)) }

    let rendered = Journal()
    let (index, blobs) = document(files, journal: rendered)
    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    try await AnnotatedPDFRenderer(blobs: blobs).renderPDF(
        documentID: "doc", index: index, to: output, maximumPages: 2,
        onPageCount: { drawn, document in rendered.append("count \(drawn) of \(document)") }
    )
    #expect(Set(rendered.pagesFetched) == ["p0", "p1"])
    let first = try #require(rendered.all.firstIndex { $0.hasSuffix(".rm") })
    #expect(rendered.all.firstIndex(of: "count 2 of 4").map { $0 < first } == true, "\(rendered.all)")

    let asked = Journal()
    let (markIndex, markBlobs) = document(files, journal: asked)
    _ = try await AnnotatedPDFRenderer(blobs: markBlobs).marks(documentID: "doc", index: markIndex, maximumPages: 1)
    #expect(asked.pagesFetched == ["p0"])
}

@Test("An annotated cap of nought or below is one page, in the render and in marks")
func annotatedCapBelowOneIsOne() async throws {
    let original = try originalPDF(pages: 3)
    let content = cPages((0..<3).map { record("p\($0)", idx: "a\($0)", redir: "\($0)") })
    for cap in [0, -5, Int.min] {
        let pdf = try await annotated(original, content: content, maximumPages: cap)
        #expect(widths(pdf) == [300], "cap \(cap)")
        let (index, blobs) = document([("doc.pdf", original), ("doc.content", content)])
        #expect(
            try await AnnotatedPDFRenderer(blobs: blobs).marks(documentID: "doc", index: index, maximumPages: cap).count == 1
        )
    }
}

// A trailing closure has two readings: the forward scan's `onProgress` and
// the backward scan's `onUnreadable`. Where `onPageCount` sits in the list
// must not take either of them — this is the source compatibility of the
// parameter. The trailing closure after labelled ones is the very spelling
// under test.
// swiftlint:disable multiple_closures_with_trailing_closure
@Test("A trailing closure means onProgress or onUnreadable, never onPageCount")
func trailingClosuresKeepTheirMeaning() async throws {
    let (index, blobs) = document([
        ("doc.content", cPages([record("good"), record("torn")])),
        ("doc/good.rm", inkedPage(0)),
        ("doc/torn.rm", Data("not a page".utf8)),
    ])
    let renderer = NotebookRenderer(blobs: blobs)

    let progress = Recorded()
    _ = try await renderer.renderPDF(documentID: "doc", index: index) { completed, _ in progress.append(completed) }
    #expect(progress.all.last == 3)

    let unreadable = Recorded()
    _ = try await renderer.renderPDF(
        documentID: "doc", index: index, onProgress: { _, _ in }, onUnsupported: { _ in }
    ) { pages in unreadable.append(pages) }
    #expect(unreadable.all == [1])

    let annotatedUnreadable = Recorded()
    let original = try originalPDF(pages: 1)
    let (markedIndex, markedBlobs) = document([
        ("doc.pdf", original),
        ("doc.content", cPages([record("torn", redir: "0")])),
        ("doc/torn.rm", Data("not a page".utf8)),
    ])
    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    try await AnnotatedPDFRenderer(blobs: markedBlobs).renderPDF(
        documentID: "doc", index: markedIndex, to: output, onProgress: { _, _ in }, onUnsupported: { _ in }
    ) { pages in annotatedUnreadable.append(pages) }
    #expect(annotatedUnreadable.all == [1])
}
// swiftlint:enable multiple_closures_with_trailing_closure

@Test("A refused redir is told from an absent one, wherever it was refused")
func refusedRedirectionsAreCounted() throws {
    let layout = try PageOrder.layout(from: cPages([
        record("absent"), record("negative", redir: "-1"), record("fraction", redir: "1.5"),
        record("null", redir: "null"), record("past", redir: "7"), record("good", redir: "0"),
    ]))
    #expect(layout.pages.map(\.refusedRedir) == [false, true, true, false, false, false])
    let checked = PageOrder.checked(layout.pages, originalPages: 3)
    #expect(checked.map(\.refusedRedir) == [false, true, true, false, true, false])

    let flat = try PageOrder.layout(from: Data(#"{"pages": ["a", "b", "c", "d"], "redirectionPageMap": [0, -1, null, "x"]}"#.utf8))
    #expect(flat.pages.map(\.refusedRedir) == [false, true, false, true])
}

@Test("An attachment that states nought and brings more than a document may hold is a hole")
func underDeclaredAttachmentIsDropped() async throws {
    let page = RMPage(
        strokes: [],
        skippedBlocks: 0,
        images: [PageImage(file: "big.png", vertices: [], strokesBefore: 0)]
    )
    let big = Data(count: PageRenderer.maximumAssetBytes + 1)
    let index = DocumentFiles(files: [DocumentFile(hash: "big", name: "doc/p0/big.png", size: 0)])
    let assets = await PageAssets.gather(for: [page], index: index, channel: "test") { _ in big }
    #expect(assets.isEmpty)

    let small = Data(count: 16)
    let kept = await PageAssets.gather(for: [page], index: index, channel: "test") { _ in small }
    #expect(kept["big.png"] == small)
}

@Test("A notebook with no page at all is told one drawn and none in the document")
func emptyNotebookCountsItsBlankSheet() async throws {
    let (index, blobs) = document([("doc.content", cPages([]))])
    let journal = Journal()
    let pdf = try open(
        try await NotebookRenderer(blobs: blobs).renderPDF(
            documentID: "doc", index: index, onPageCount: { drawn, document in journal.append("\(drawn) of \(document)") }
        )
    )
    #expect(pdf.numberOfPages == 1)
    #expect(journal.all == ["1 of 0"])
}
