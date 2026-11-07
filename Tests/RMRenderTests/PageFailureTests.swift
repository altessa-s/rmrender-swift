// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import RMLines
@testable import RMRender
import Testing

// A page whose bytes do not arrive costs that page and no more. What these
// guard is that every route — a notebook's PDF and bitmaps, an annotated
// document overlaid or redrawn — draws such a page exactly as it draws a page
// whose bytes did not parse, says so once through `onUnfetched` and not
// through `onUnreadable`, and still stops dead when the render is cancelled.

// MARK: - Fixtures

/// How a page's blob misbehaves.
enum FetchFailure: Sendable {
    /// Every fetch fails.
    case always
    /// The first fetch — the measuring — succeeds, every later one fails.
    case afterFirst
    /// The fetch answers `CancellationError` without anybody cancelling.
    case cancellation
    /// The fetch waits until the render is cancelled, then fails the way a
    /// transport does — with an error of its own rather than
    /// `CancellationError`.
    case hangUntilCancelled
}

struct Unreachable: Error {}

private final class FetchCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var started = false

    /// The number of this fetch of `name`, from one.
    func next(_ name: String) -> Int {
        lock.withLock {
            counts[name, default: 0] += 1
            return counts[name] ?? 0
        }
    }

    func markStarted() { lock.withLock { started = true } }
    var hasStarted: Bool { lock.withLock { started } }
}

private struct FlakyBlobs: PageBlobs {
    let blobs: [String: Data]
    let failures: [String: FetchFailure]
    let counts = FetchCounts()

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        let attempt = counts.next(name)
        switch failures[name] {
        case .always?:
            throw Unreachable()
        case .afterFirst? where attempt > 1:
            throw Unreachable()
        case .cancellation?:
            throw CancellationError()
        case .hangUntilCancelled?:
            counts.markStarted()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                throw URLError(.cancelled)
            }
            throw Unreachable()
        default:
            break
        }
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
        let url = FileManager.default.temporaryDirectory.appending(path: "rmrender-flaky-\(UUID().uuidString).pdf")
        try bytes.write(to: url)
        return BlobFile(url: url, isTemporary: true)
    }
}

/// What one render reported, through the callbacks.
private final class Tallies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [Int]] = [:]

    func note(_ name: String, _ value: Int) { lock.withLock { values[name, default: []].append(value) } }
    func calls(_ name: String) -> [Int] { lock.withLock { values[name] ?? [] } }
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
    for page in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 20 + page, y: 20, width: 30, height: 30))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

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

private func bitmap(_ image: CGImage) throws -> Data {
    try #require(image.dataProvider?.data) as Data
}

private func temporaryPDF() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rmrender-failure-\(UUID().uuidString).pdf")
}

/// The page at `lost` is the one whose bytes go astray; the same document with
/// that page torn is the reference — the page drawn as an unreadable one is.
private let pageCount = 10
private let lost = 4

private func notebook(tearing torn: Int? = nil) -> [(name: String, bytes: Data)] {
    let ids = (0..<pageCount).map { "p\($0)" }
    return (0..<pageCount).map { page in
        ("doc/p\(page).rm", page == torn ? Data("not a page".utf8) : inkedPage(page))
    } + [("doc.content", cPages(ids, template: "Isometric"))]
}

private func annotated(tearing torn: Int? = nil) throws -> [(name: String, bytes: Data)] {
    let ids = (0..<pageCount).map { "p\($0)" }
    return [("doc.pdf", try originalPDF(pages: pageCount)), ("doc.content", cPages(ids, redirs: true))]
        + (0..<pageCount).map { page in
            ("doc/p\(page).rm", page == torn ? Data("not a page".utf8) : inkedPage(page))
        }
}

// MARK: - Notebooks

@Test("A notebook page whose bytes do not arrive is drawn as an unreadable one, and told once as unfetched",
      arguments: [FetchFailure.always, .afterFirst])
func notebookPDFLosesOnlyTheUnfetchedPage(_ failure: FetchFailure) async throws {
    let (index, store) = document(notebook())
    let tallies = Tallies()
    let renderer = NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": failure]))
    let pdf = try await renderer.renderPDF(
        documentID: "doc", index: index,
        onUnfetched: { tallies.note("unfetched", $0) },
        onUnreadable: { tallies.note("unreadable", $0) }
    )
    #expect(tallies.calls("unfetched") == [1])
    #expect(tallies.calls("unreadable").isEmpty)

    let (tornIndex, tornStore) = document(notebook(tearing: lost))
    let reference = try await NotebookRenderer(blobs: FlakyBlobs(blobs: tornStore, failures: [:]))
        .renderPDF(documentID: "doc", index: tornIndex, onUnreadable: { tallies.note("reference", $0) })
    #expect(tallies.calls("reference") == [1])
    #expect(try pixels(pdf) == pixels(reference))

    // The file route draws the same pages and tells the same news.
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    let fileTallies = Tallies()
    try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": failure])).renderPDF(
        documentID: "doc", index: index, to: output, onUnfetched: { fileTallies.note("unfetched", $0) }
    )
    #expect(fileTallies.calls("unfetched") == [1])
    #expect(try pixels(Data(contentsOf: output)) == pixels(reference))
}

@Test("A notebook's bitmaps and its parse carry an unfetched page as an unreadable sheet, and name it")
func notebookImagesLoseOnlyTheUnfetchedPage() async throws {
    let (index, store) = document(notebook())
    let tallies = Tallies()
    let blobs = FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": .always])
    let images = try await NotebookRenderer(blobs: blobs).renderImages(
        documentID: "doc", index: index, onUnfetched: { tallies.note("unfetched", $0) }
    )
    #expect(tallies.calls("unfetched") == [1])
    #expect(images.count == pageCount)

    let parsed = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": .always]))
        .parsed(documentID: "doc", index: index)
    #expect(parsed.unfetched == [lost])
    #expect(parsed.unreadable == [lost])

    let (tornIndex, tornStore) = document(notebook(tearing: lost))
    let reference = try await NotebookRenderer(blobs: FlakyBlobs(blobs: tornStore, failures: [:]))
        .renderImages(documentID: "doc", index: tornIndex)
    #expect(try images.map(bitmap) == reference.map(bitmap))
}

// MARK: - Annotated documents

@Test("An annotated page whose marks do not arrive goes out without them, overlaid or redrawn",
      arguments: [FetchFailure.always, .afterFirst], [true, false])
func annotatedLosesOnlyTheUnfetchedMarks(_ failure: FetchFailure, overlay: Bool) async throws {
    let files = try annotated()
    let (index, store) = document(files)
    let tallies = Tallies()
    let output = temporaryPDF()
    let reference = temporaryPDF()
    defer {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: reference)
    }
    try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": failure])).renderPDF(
        documentID: "doc", index: index, to: output, allowOverlay: overlay,
        onUnfetched: { tallies.note("unfetched", $0) },
        onUnreadable: { tallies.note("unreadable", $0) }
    )
    #expect(tallies.calls("unfetched") == [1])
    #expect(tallies.calls("unreadable").isEmpty)

    let (tornIndex, tornStore) = document(try annotated(tearing: lost))
    try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: tornStore, failures: [:])).renderPDF(
        documentID: "doc", index: tornIndex, to: reference, allowOverlay: overlay
    )
    let written = try Data(contentsOf: output)
    #expect(try pixels(written) == pixels(Data(contentsOf: reference)))
    if overlay {
        // Still an incremental update of the original, not a redraw.
        let original = try #require(files.first { $0.name == "doc.pdf" }).bytes
        #expect(written.prefix(original.count) == original)
    }
}

@Test("Where the marks are is not answered with marks that did not arrive")
func marksStayStrict() async throws {
    let (index, store) = document(try annotated())
    await #expect(throws: Unreachable.self) {
        _ = try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": .always]))
            .marks(documentID: "doc", index: index)
    }
}

// MARK: - Cancellation

@Test("A cancellation answered by a fetch still ends every route")
func cancellationFromAFetchEndsTheRender() async throws {
    let failures: [String: FetchFailure] = ["doc/p\(lost).rm": .cancellation]
    let (notebookIndex, notebookStore) = document(notebook())
    await #expect(throws: CancellationError.self) {
        _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: notebookStore, failures: failures))
            .renderPDF(documentID: "doc", index: notebookIndex)
    }
    await #expect(throws: CancellationError.self) {
        _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: notebookStore, failures: failures))
            .renderImages(documentID: "doc", index: notebookIndex)
    }
    let (index, store) = document(try annotated())
    for overlay in [true, false] {
        let output = temporaryPDF()
        await #expect(throws: CancellationError.self) {
            try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
                documentID: "doc", index: index, to: output, allowOverlay: overlay
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@Test("Cancelling a render whose fetch is in flight ends it, whatever error the transport answers with")
func cancellingTheCallerEndsTheRender() async throws {
    let failures: [String: FetchFailure] = ["doc/p\(lost).rm": .hangUntilCancelled]
    let (notebookIndex, notebookStore) = document(notebook())
    let notebookBlobs = FlakyBlobs(blobs: notebookStore, failures: failures)
    let notebookOutput = temporaryPDF()
    let notebookTallies = Tallies()
    let notebookRender = Task {
        try await NotebookRenderer(blobs: notebookBlobs).renderPDF(
            documentID: "doc", index: notebookIndex, to: notebookOutput,
            onUnfetched: { notebookTallies.note("unfetched", $0) }
        )
    }
    while !notebookBlobs.counts.hasStarted { await Task.yield() }
    notebookRender.cancel()
    await #expect(throws: (any Error).self) { try await notebookRender.value }
    #expect(notebookTallies.calls("unfetched").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: notebookOutput.path))

    let (index, store) = document(try annotated())
    let blobs = FlakyBlobs(blobs: store, failures: failures)
    let output = temporaryPDF()
    let tallies = Tallies()
    let render = Task {
        try await AnnotatedPDFRenderer(blobs: blobs).renderPDF(
            documentID: "doc", index: index, to: output, onUnfetched: { tallies.note("unfetched", $0) }
        )
    }
    while !blobs.counts.hasStarted { await Task.yield() }
    render.cancel()
    await #expect(throws: (any Error).self) { try await render.value }
    #expect(tallies.calls("unfetched").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test("A missing original is still the whole render's failure")
func missingOriginalStillFails() async throws {
    let files = try annotated().filter { $0.name != "doc.pdf" }
    let (index, store) = document(files)
    await #expect(throws: RenderError.self) {
        try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: [:])).renderPDF(
            documentID: "doc", index: index, to: temporaryPDF()
        )
    }
}
