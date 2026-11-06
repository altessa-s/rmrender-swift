// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Foundation
import RMLines
@testable import RMRender
import Testing

// A PDF export measures every page first and keeps nothing of it, then parses
// each page again when it is drawn and lets it go. What these guard is that
// the drawing holds no more than a window of parsed pages, that each page is
// read once to be measured and once to be drawn, and that what comes out is
// what drawing every page parsed up front made.

// MARK: - Fixtures

/// Every fetch, by blob name, and how far the drawing had got when it came.
private final class Fetches: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var drawn = 0
    /// For each page fetched a second time — to be drawn — how many pages
    /// ahead of the drawing it was.
    private var leads: [Int] = []

    func fetched(_ name: String) {
        lock.withLock {
            counts[name, default: 0] += 1
            // Pages are `doc/p<n>.rm`, counted from nought.
            guard counts[name] == 2, let page = Int(name.dropFirst("doc/p".count).dropLast(".rm".count)) else { return }
            leads.append(page - drawn)
        }
    }

    func drew(_ pages: Int) {
        lock.withLock { drawn = pages }
    }

    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var furthestLead: Int { lock.withLock { leads.max() ?? 0 } }
    var secondFetches: Int { lock.withLock { leads.count } }
}

private struct CountingBlobs: PageBlobs {
    let blobs: [String: Data]
    let fetches: Fetches

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        fetches.fetched(name)
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
        guard let bytes = blobs[hash] else { throw RenderError.malformedPage(name) }
        let url = FileManager.default.temporaryDirectory.appending(path: "rmrender-lazy-\(UUID().uuidString).blob")
        try bytes.write(to: url)
        return BlobFile(url: url, isTemporary: true)
    }
}

private func document(_ files: [(name: String, bytes: Data)]) -> (index: DocumentFiles, blobs: [String: Data]) {
    var store: [String: Data] = [:]
    let entries = files.map { file in
        let hash = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
        store[hash] = file.bytes
        return DocumentFile(hash: hash, name: file.name, size: Int64(file.bytes.count))
    }
    return (DocumentFiles(files: entries), store)
}

/// A page with a stroke of its own, so no two pages share bytes.
private func inkedPage(_ seed: Int) -> Data {
    makePage(points: (0...12).map {
        StrokeSample(x: Float(-500 + $0 * 70 + seed), y: Float(200 + seed * 11 + $0 * 9), width: 20)
    })
}

private func cPages(_ ids: [String], redirs: Bool = false, template: String? = nil) -> Data {
    let records = ids.enumerated().map { position, id in
        var fields = [#""id": "\#(id)""#]
        if redirs { fields.append(#""redir": {"timestamp": "1:2", "value": \#(position)}"#) }
        if let template { fields.append(#""template": {"timestamp": "1:2", "value": "\#(template)"}"#) }
        return "{\(fields.joined(separator: ", "))}"
    }
    return Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(records.joined(separator: ", "))]}}"#.utf8)
}

private func originalPDF(pages: Int) throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 20, y: 20, width: 30, height: 30))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// Every page of a PDF as pixels, drawn by CoreGraphics at its own size.
private func pixels(_ pdf: Data) throws -> [[UInt8]] {
    let document = try #require(CGDataProvider(data: pdf as CFData).flatMap(CGPDFDocument.init))
    return try (1...max(document.numberOfPages, 1)).map { number in
        let page = try #require(document.page(at: number))
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width.rounded()), height = Int(box.height.rounded())
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        return Array(UnsafeBufferPointer(start: buffer, count: width * height * 4))
    }
}

// MARK: - The window

@Test("A window of answers: in order, each consumed once, never more than the window held at once")
func boundedForEachHoldsAWindow() async throws {
    let jobs = Array(0..<60)
    let live = LiveCount()
    var consumed: [Int] = []
    try await RenderWork.boundedConcurrentForEach(jobs, limit: 4) { job in
        // Out of order on purpose: an early job that finishes last must not
        // let the ones behind it pile up.
        try await Task.sleep(for: .milliseconds(job.isMultiple(of: 5) ? 6 : 1))
        live.produced()
        return job * 10
    } consume: { position, value in
        #expect(value == jobs[position] * 10)
        consumed.append(position)
        live.consumed()
    }
    #expect(consumed == jobs)
    #expect(live.most <= 4)
}

@Test("A window ends at the first failure, of a job or of the consumer")
func boundedForEachStopsAtAFailure() async throws {
    struct Stop: Error {}
    var seen: [Int] = []
    await #expect(throws: Stop.self) {
        try await RenderWork.boundedConcurrentForEach(Array(0..<20), limit: 3) { job in
            if job == 7 { throw Stop() }
            return job
        } consume: { _, value in
            seen.append(value)
        }
    }
    // In order and none past the failure; how many came before it is the
    // scheduler's to say.
    #expect(seen == Array(0..<seen.count) && seen.count <= 7)
    await #expect(throws: Stop.self) {
        try await RenderWork.boundedConcurrentForEach(Array(0..<20), limit: 3) { $0 } consume: { _, value in
            if value == 2 { throw Stop() }
        }
    }
}

/// Answers made and not yet consumed, and the most there ever were.
private final class LiveCount: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = 0
    private var highest = 0

    func produced() {
        lock.withLock {
            waiting += 1
            highest = max(highest, waiting)
        }
    }

    func consumed() { lock.withLock { waiting -= 1 } }
    var most: Int { lock.withLock { highest } }
}

// MARK: - Notebooks

private func notebook(pages: Int) -> [(name: String, bytes: Data)] {
    // Page 3 is torn and page 5 was never written on: both are sheets the
    // walk makes itself, and neither may be fetched to be drawn.
    var ids: [String] = []
    var files: [(name: String, bytes: Data)] = []
    for page in 0..<pages {
        ids.append("p\(page)")
        if page == 5 { continue }
        files.append(("doc/p\(page).rm", page == 3 ? Data("not a page".utf8) : inkedPage(page)))
    }
    return files + [("doc.content", cPages(ids, template: "Isometric"))]
}

@Test("A notebook's PDF reads each written page twice — measured, then drawn — and draws what the parse holds")
func notebookPagesAreParsedWhenDrawn() async throws {
    let (index, store) = document(notebook(pages: 30))
    let fetches = Fetches()
    let renderer = NotebookRenderer(blobs: CountingBlobs(blobs: store, fetches: fetches))
    let lazy = try await renderer.renderPDF(documentID: "doc", index: index)

    for page in 0..<30 where page != 5 {
        #expect(fetches.count("doc/p\(page).rm") == (page == 3 ? 1 : 2), "page \(page)")
    }
    #expect(fetches.count("doc/p5.rm") == 0)

    // What drawing every page parsed up front makes, as the export did.
    let parsed = try await NotebookRenderer(blobs: CountingBlobs(blobs: store, fetches: Fetches()))
        .parsed(documentID: "doc", index: index)
    let eager = try PageRenderer.pdf(pages: parsed.pages, pageSize: parsed.pageSize, assets: parsed.assets)
    #expect(try pixels(lazy) == pixels(eager))

    // And the file route draws the same pages.
    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-lazy-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    try await renderer.renderPDF(documentID: "doc", index: index, to: output)
    #expect(try pixels(Data(contentsOf: output)) == pixels(eager))
}

@Test("A notebook with no page at all is still one blank sheet when drawn lazily")
func emptyNotebookStillDrawsASheet() async throws {
    let (index, store) = document([("doc.content", cPages([]))])
    let pdf = try await NotebookRenderer(blobs: CountingBlobs(blobs: store, fetches: Fetches()))
        .renderPDF(documentID: "doc", index: index)
    #expect(try pixels(pdf) == pixels(try PageRenderer.pdf(pages: [])))
}

// MARK: - Annotated documents

private func annotatedDocument(pages: Int) throws -> [(name: String, bytes: Data)] {
    let ids = (0..<pages).map { "p\($0)" }
    // Page 2 carries no marks at all, and nothing of it is fetched to draw.
    return [("doc.pdf", try originalPDF(pages: pages)), ("doc.content", cPages(ids, redirs: true))]
        + (0..<pages).filter { $0 != 2 }.map { ("doc/p\($0).rm", inkedPage($0)) }
}

@Test("A redraw parses a page's marks when it comes to the page, never further ahead than the window")
func redrawHoldsAWindowOfMarks() async throws {
    let pages = 40
    let (index, store) = document(try annotatedDocument(pages: pages))
    let fetches = Fetches()
    let originalBytes = Int64(try #require(index.file(withExtension: "pdf")).size)
    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-lazy-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    try await AnnotatedPDFRenderer(blobs: CountingBlobs(blobs: store, fetches: fetches)).renderPDF(
        documentID: "doc", index: index, to: output, allowOverlay: false,
        onProgress: { completed, _ in
            if completed > originalBytes { fetches.drew(Int(completed - originalBytes)) }
        }
    )
    #expect(fetches.secondFetches == pages - 1)
    #expect(fetches.furthestLead <= RenderWork.pageConcurrency)
    #expect(fetches.count("doc/p2.rm") == 0)
    #expect(try #require(CGPDFDocument(output as CFURL)).numberOfPages == pages)
}

@Test("The overlay reads each marked page twice and draws the redraw's marks")
func overlayParsesMarksWhenWritten() async throws {
    let pages = 12
    let files = try annotatedDocument(pages: pages)
    let (index, store) = document(files)
    let fetches = Fetches()
    let renderer = AnnotatedPDFRenderer(blobs: CountingBlobs(blobs: store, fetches: fetches))
    let overlaid = FileManager.default.temporaryDirectory.appending(path: "rmrender-lazy-\(UUID().uuidString).pdf")
    let redrawn = FileManager.default.temporaryDirectory.appending(path: "rmrender-lazy-\(UUID().uuidString).pdf")
    defer {
        try? FileManager.default.removeItem(at: overlaid)
        try? FileManager.default.removeItem(at: redrawn)
    }
    try await renderer.renderPDF(documentID: "doc", index: index, to: overlaid)
    for page in 0..<pages where page != 2 {
        #expect(fetches.count("doc/p\(page).rm") == 2, "page \(page)")
    }
    // The overlay is an incremental update of the original: it has to be one.
    let original = try #require(files.first { $0.name == "doc.pdf" }).bytes
    let written = try Data(contentsOf: overlaid)
    #expect(written.prefix(original.count) == original)

    try await renderer.renderPDF(documentID: "doc", index: index, to: redrawn, allowOverlay: false)
    #expect(try pixels(written).count == pages)
    #expect(try pixels(Data(contentsOf: redrawn)).count == pages)
}
