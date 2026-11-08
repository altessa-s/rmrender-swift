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
// document overlaid or redrawn — draws such a page, under `.blank`, exactly
// as it draws a page whose bytes did not parse, under `.placeholder` with the
// label and nothing else changed, and under `.strict` not at all; says so
// once through `onUnfetched` and not through `onUnreadable`; and still stops
// dead when the render is cancelled.

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

private func notebook(tearing torn: Int? = nil, template: String = "Isometric") -> [(name: String, bytes: Data)] {
    let ids = (0..<pageCount).map { "p\($0)" }
    return (0..<pageCount).map { page in
        ("doc/p\(page).rm", page == torn ? Data("not a page".utf8) : inkedPage(page))
    } + [("doc.content", cPages(ids, template: template))]
}

/// A notebook on a template the fixtures install, so that a page drawn on
/// it shows the ruling in every process, whatever ran before.
private func ruledNotebook() -> [(name: String, bytes: Data)] {
    _ = FixtureTemplates.installed
    return notebook(template: "Fixture Lines")
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
        documentID: "doc", index: index, unfetchedPages: .blank,
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
        documentID: "doc", index: index, to: output, unfetchedPages: .blank,
        onUnfetched: { fileTallies.note("unfetched", $0) }
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
        documentID: "doc", index: index, unfetchedPages: .blank, onUnfetched: { tallies.note("unfetched", $0) }
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
        documentID: "doc", index: index, to: output, allowOverlay: overlay, unfetchedPages: .blank,
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

@Test("A cancellation answered by a fetch still ends every route, whatever is asked of unfetched pages",
      arguments: [UnfetchedPagePolicy.placeholder, .blank, .strict])
func cancellationFromAFetchEndsTheRender(_ policy: UnfetchedPagePolicy) async throws {
    let failures: [String: FetchFailure] = ["doc/p\(lost).rm": .cancellation]
    let (notebookIndex, notebookStore) = document(notebook())
    await #expect(throws: CancellationError.self) {
        _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: notebookStore, failures: failures))
            .renderPDF(documentID: "doc", index: notebookIndex, unfetchedPages: policy)
    }
    await #expect(throws: CancellationError.self) {
        _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: notebookStore, failures: failures))
            .renderImages(documentID: "doc", index: notebookIndex, unfetchedPages: policy)
    }
    let (index, store) = document(try annotated())
    for overlay in [true, false] {
        let output = temporaryPDF()
        await #expect(throws: CancellationError.self) {
            try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
                documentID: "doc", index: index, to: output, allowOverlay: overlay, unfetchedPages: policy
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@Test("Cancelling a render whose fetch is in flight ends it, whatever error the transport answers with",
      arguments: [UnfetchedPagePolicy.placeholder, .blank, .strict])
func cancellingTheCallerEndsTheRender(_ policy: UnfetchedPagePolicy) async throws {
    let failures: [String: FetchFailure] = ["doc/p\(lost).rm": .hangUntilCancelled]
    let (notebookIndex, notebookStore) = document(notebook())
    let notebookBlobs = FlakyBlobs(blobs: notebookStore, failures: failures)
    let notebookOutput = temporaryPDF()
    let notebookTallies = Tallies()
    let notebookRender = Task {
        try await NotebookRenderer(blobs: notebookBlobs).renderPDF(
            documentID: "doc", index: notebookIndex, to: notebookOutput, unfetchedPages: policy,
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
            documentID: "doc", index: index, to: output, unfetchedPages: policy,
            onUnfetched: { tallies.note("unfetched", $0) }
        )
    }
    while !blobs.counts.hasStarted { await Task.yield() }
    render.cancel()
    await #expect(throws: (any Error).self) { try await render.value }
    #expect(tallies.calls("unfetched").isEmpty)
    // Ended by the cancelling, not named as a page that did not arrive.
    for result in [await notebookRender.result, await render.result] {
        guard case .failure(let error) = result else {
            Issue.record("a cancelled render finished")
            continue
        }
        #expect(!(error is PageFetchError))
    }
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

// MARK: - What is asked of unfetched pages

/// A page of a PDF or a bitmap as pixels, white under everything.
private struct Raster: Equatable {
    let width: Int
    let height: Int
    /// RGBA, a row after another, from the top.
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init(_ image: CGImage) throws {
        let context = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        self.init(
            width: image.width, height: image.height,
            bytes: Array(UnsafeBufferPointer(start: buffer, count: image.width * image.height * 4))
        )
    }

    static func pages(_ pdf: Data) throws -> [Raster] {
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
            return Raster(width: width, height: height, bytes: Array(UnsafeBufferPointer(start: buffer, count: width * height * 4)))
        }
    }

    /// Where the label stands: the middle of the sheet, a band a tenth of
    /// the width high and three fifths of it wide — room around the label's
    /// own box on every side.
    func isLabel(x: Int, y: Int) -> Bool {
        let middle = Double(height) / 2, band = Double(width) * 0.1
        return Double(x) > Double(width) * 0.2 && Double(x) < Double(width) * 0.8
            && abs(Double(y) - middle) < band
    }

    func pixel(x: Int, y: Int) -> ArraySlice<UInt8> {
        let start = (y * width + x) * 4
        return bytes[start..<start + 4]
    }

    /// Pixels in the label's band that are darker than the label's box —
    /// the letters.
    var letters: Int {
        var count = 0
        for y in 0..<height {
            for x in 0..<width where isLabel(x: x, y: y) && pixel(x: x, y: y).prefix(3).allSatisfy({ $0 < 128 }) {
                count += 1
            }
        }
        return count
    }

    /// Whether everything outside the label's band is white.
    var isBlankOutsideLabel: Bool {
        for y in 0..<height {
            for x in 0..<width where !isLabel(x: x, y: y) && pixel(x: x, y: y).contains(where: { $0 != 255 }) {
                return false
            }
        }
        return true
    }

    /// Whether `other` is the same picture everywhere outside the label's
    /// band.
    func matchesOutsideLabel(_ other: Raster) -> Bool {
        guard width == other.width, height == other.height else { return false }
        for y in 0..<height {
            for x in 0..<width where !isLabel(x: x, y: y) && pixel(x: x, y: y) != other.pixel(x: x, y: y) {
                return false
            }
        }
        return true
    }
}

private func pageFetchError(_ body: () async throws -> Void) async -> PageFetchError? {
    do {
        try await body()
    } catch let error as PageFetchError {
        return error
    } catch {
        Issue.record("failed with \(error) rather than PageFetchError")
        return nil
    }
    Issue.record("did not fail")
    return nil
}

@Test("A notebook page whose bytes do not arrive is drawn with the label alone, on a plain sheet, by default",
      arguments: [FetchFailure.always, .afterFirst])
func notebookPDFDrawsThePlaceholder(_ failure: FetchFailure) async throws {
    let (index, store) = document(ruledNotebook())
    let failures = ["doc/p\(lost).rm": failure]
    let tallies = Tallies()
    let pdf = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
        documentID: "doc", index: index,
        onUnfetched: { tallies.note("unfetched", $0) },
        onUnreadable: { tallies.note("unreadable", $0) }
    )
    #expect(tallies.calls("unfetched") == [1])
    #expect(tallies.calls("unreadable").isEmpty)
    let blank = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures))
        .renderPDF(documentID: "doc", index: index, unfetchedPages: .blank)

    let pages = try Raster.pages(pdf), blankPages = try Raster.pages(blank)
    #expect(pages.count == pageCount)
    for page in 0..<pageCount where page != lost {
        #expect(pages[page] == blankPages[page], "page \(page)")
    }
    let placeholder = pages[lost]
    #expect(placeholder.width == blankPages[lost].width && placeholder.height == blankPages[lost].height)
    #expect(placeholder.letters > 200)
    // No template: a sheet that cannot be taken for one nobody wrote on.
    #expect(placeholder.isBlankOutsideLabel)
    #expect(!blankPages[lost].isBlankOutsideLabel)

    // The file route draws the same.
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    let fileTallies = Tallies()
    try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
        documentID: "doc", index: index, to: output, unfetchedPages: .placeholder,
        onUnfetched: { fileTallies.note("unfetched", $0) }
    )
    #expect(fileTallies.calls("unfetched") == [1])
    #expect(try Raster.pages(Data(contentsOf: output)) == pages)
}

@Test("A notebook's bitmaps carry the label where the bytes did not arrive, in colour and in grey")
func notebookImagesDrawThePlaceholder() async throws {
    let (index, store) = document(ruledNotebook())
    let blobs = FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": .always])
    let renderer = NotebookRenderer(blobs: blobs)
    for grayscale in [false, true] {
        let tallies = Tallies()
        let images = try await renderer.renderImages(
            documentID: "doc", index: index, grayscale: grayscale, onUnfetched: { tallies.note("unfetched", $0) }
        )
        #expect(tallies.calls("unfetched") == [1])
        let blank = try await renderer.renderImages(
            documentID: "doc", index: index, grayscale: grayscale, unfetchedPages: .blank
        )
        #expect(images.count == pageCount)
        for page in 0..<pageCount where page != lost {
            #expect(try bitmap(images[page]) == bitmap(blank[page]), "page \(page)")
        }
        let placeholder = try Raster(images[lost])
        #expect(placeholder.width == blank[lost].width && placeholder.height == blank[lost].height)
        #expect(placeholder.letters > 200)
        #expect(placeholder.isBlankOutsideLabel)
        #expect(try !Raster(blank[lost]).isBlankOutsideLabel)
        #expect(images[lost].bitsPerPixel == blank[lost].bitsPerPixel)
    }

    // The same out of a parse, a window at a time, and the label is the
    // drawing's: the parse keeps the page as it was.
    let parsed = try await renderer.parsed(documentID: "doc", index: index)
    #expect(parsed.unfetched == [lost])
    let window = try await renderer.renderImages(parsed, pages: (lost - 1)..<(lost + 1))
    #expect(try Raster(window[1]).letters > 200)
    let before = try await renderer.renderImages(parsed, pages: (lost - 1)..<lost)
    #expect(try bitmap(window[0]) == bitmap(before[0]))
    let blankWindow = try await renderer.renderImages(parsed, pages: lost..<(lost + 1), unfetchedPages: .blank)
    #expect(try Raster(blankWindow[0]).letters == 0)
    // A window that leaves the page out is not failed for it.
    _ = try await renderer.renderImages(parsed, pages: 0..<lost, unfetchedPages: .strict)
    let error = await pageFetchError {
        _ = try await renderer.renderImages(parsed, pages: 0..<pageCount, unfetchedPages: .strict)
    }
    #expect(error?.page == lost)
    #expect(error?.pageID == "p\(lost)")
    #expect(error?.underlying is Unreachable)

    // Handwriting alone has no label to show.
    let ink = try await renderer.renderInkImages(documentID: "doc", index: index, pages: [lost])
    let blankInk = try await renderer.renderInkImages(
        documentID: "doc", index: index, pages: [lost], unfetchedPages: .blank
    )
    #expect(try bitmap(try #require(ink[lost])) == bitmap(try #require(blankInk[lost])))
}

@Test("Strict: a notebook whose page did not arrive is not drawn, and the error names the page",
      arguments: [FetchFailure.always, .afterFirst])
func notebookStrictFails(_ failure: FetchFailure) async throws {
    let (index, store) = document(notebook())
    let failures = ["doc/p\(lost).rm": failure]
    let tallies = Tallies()
    let error = await pageFetchError {
        _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
            documentID: "doc", index: index, unfetchedPages: .strict, onUnfetched: { tallies.note("unfetched", $0) }
        )
    }
    #expect(error?.page == lost)
    #expect(error?.pageID == "p\(lost)")
    #expect(error?.underlying is Unreachable)
    #expect(error.map(String.init(describing:))?.contains("p\(lost)") == true)
    #expect(tallies.calls("unfetched").isEmpty)

    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    let fileError = await pageFetchError {
        try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
            documentID: "doc", index: index, to: output, unfetchedPages: .strict
        )
    }
    #expect(fileError?.page == lost)
    #expect(!FileManager.default.fileExists(atPath: output.path))

    // A parse fetches a page once: only a first fetch that fails fails it.
    if failure == .always {
        let imageError = await pageFetchError {
            _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderImages(
                documentID: "doc", index: index, unfetchedPages: .strict
            )
        }
        #expect(imageError?.page == lost)
        let parseError = await pageFetchError {
            _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures))
                .parsed(documentID: "doc", index: index, unfetchedPages: .strict)
        }
        #expect(parseError?.page == lost)
        let inkError = await pageFetchError {
            _ = try await NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: failures))
                .renderInkImages(documentID: "doc", index: index, pages: [0], unfetchedPages: .strict)
        }
        #expect(inkError?.page == lost)
    }
}

@Test("A page that would not parse is drawn as it always was, whatever is asked of unfetched pages",
      arguments: [UnfetchedPagePolicy.placeholder, .blank, .strict])
func unreadablePagesAreNotPlaceholders(_ policy: UnfetchedPagePolicy) async throws {
    let (index, store) = document(notebook(tearing: lost))
    let tallies = Tallies()
    let renderer = NotebookRenderer(blobs: FlakyBlobs(blobs: store, failures: [:]))
    let pdf = try await renderer.renderPDF(
        documentID: "doc", index: index, unfetchedPages: policy, onUnfetched: { tallies.note("unfetched", $0) }
    )
    #expect(tallies.calls("unfetched").isEmpty)
    let blank = try await renderer.renderPDF(documentID: "doc", index: index, unfetchedPages: .blank)
    #expect(try pixels(pdf) == pixels(blank))
}

@Test("An annotated page whose marks do not arrive goes out as the original's page with the label over it",
      arguments: [FetchFailure.always, .afterFirst], [true, false])
func annotatedDrawsThePlaceholder(_ failure: FetchFailure, overlay: Bool) async throws {
    let files = try annotated()
    let (index, store) = document(files)
    let failures = ["doc/p\(lost).rm": failure]
    let tallies = Tallies()
    let output = temporaryPDF()
    let blank = temporaryPDF()
    defer {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: blank)
    }
    try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
        documentID: "doc", index: index, to: output, allowOverlay: overlay,
        onUnfetched: { tallies.note("unfetched", $0) },
        onUnreadable: { tallies.note("unreadable", $0) }
    )
    #expect(tallies.calls("unfetched") == [1])
    #expect(tallies.calls("unreadable").isEmpty)
    try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
        documentID: "doc", index: index, to: blank, allowOverlay: overlay, unfetchedPages: .blank
    )
    let written = try Data(contentsOf: output)
    let pages = try Raster.pages(written), blankPages = try Raster.pages(Data(contentsOf: blank))
    #expect(pages.count == pageCount)
    for page in 0..<pageCount where page != lost {
        #expect(pages[page] == blankPages[page], "page \(page)")
    }
    // The original stays visible around the label, and the label is there.
    #expect(pages[lost].matchesOutsideLabel(blankPages[lost]))
    #expect(!blankPages[lost].isBlankOutsideLabel)
    #expect(pages[lost].letters > 100)
    #expect(blankPages[lost].letters == 0)
    if overlay {
        // Still an incremental update of the original, not a redraw.
        let original = try #require(files.first { $0.name == "doc.pdf" }).bytes
        #expect(written.prefix(original.count) == original)
    }
}

@Test("A page added on the tablet whose marks do not arrive is a plain sheet with the label")
func annotatedAddedPageDrawsThePlaceholder() async throws {
    // Page 4 stands on no original: the document is redrawn.
    let ids = (0..<pageCount).map { "p\($0)" }
    let records = ids.enumerated().map { position, id in
        position == lost ? #"{"id": "\#(id)"}"# : #"{"id": "\#(id)", "redir": {"timestamp": "1:2", "value": \#(position)}}"#
    }
    let content = Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(records.joined(separator: ", "))]}}"#.utf8)
    let files = [("doc.pdf", try originalPDF(pages: pageCount)), ("doc.content", content)]
        + (0..<pageCount).map { ("doc/p\($0).rm", inkedPage($0)) }
    let (index, store) = document(files)
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": .always]))
        .renderPDF(documentID: "doc", index: index, to: output)
    let page = try Raster.pages(Data(contentsOf: output))[lost]
    #expect(page.letters > 200)
    #expect(page.isBlankOutsideLabel)
}

@Test("Strict: an annotated document whose marks did not arrive is not written, and the error names the page",
      arguments: [FetchFailure.always, .afterFirst], [true, false])
func annotatedStrictFails(_ failure: FetchFailure, overlay: Bool) async throws {
    let (index, store) = document(try annotated())
    let tallies = Tallies()
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    let error = await pageFetchError {
        try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: ["doc/p\(lost).rm": failure]))
            .renderPDF(
                documentID: "doc", index: index, to: output, allowOverlay: overlay, unfetchedPages: .strict,
                onUnfetched: { tallies.note("unfetched", $0) }
            )
    }
    #expect(error?.page == lost)
    #expect(error?.pageID == "p\(lost)")
    #expect(error?.underlying is Unreachable)
    #expect(tallies.calls("unfetched").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test("Placeholders are the same bytes from one render to the next")
func placeholdersAreRepeatable() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-placeholder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appending(path: "first"), second = folder.appending(path: "second")
    try await writePlaceholders(into: first)
    try await writePlaceholders(into: second)
    for name in placeholderOutputs {
        #expect(
            InkTesting.normalized(try Data(contentsOf: first.appending(path: name)))
                == InkTesting.normalized(try Data(contentsOf: second.appending(path: name))),
            "\(name)"
        )
    }
}

// MARK: - Placeholders from every process

/// Where `writePlaceholdersForAnotherProcess` writes: set only in a process
/// `placeholdersAreTheSameInEveryProcess` starts.
private let placeholderOutputKey = "RMRENDER_TEST_PLACEHOLDER_OUTPUT"

private let placeholderOutputs = ["notebook.pdf", "overlay.pdf", "redraw.pdf"]

/// A notebook and an annotated document, overlaid and redrawn, with two
/// pages each whose bytes do not arrive — the label written several times
/// over, and shared.
private func writePlaceholders(into folder: URL) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let failures: [String: FetchFailure] = ["doc/p\(lost).rm": .always, "doc/p7.rm": .always]
    let (notebookIndex, notebookStore) = document(ruledNotebook())
    try await NotebookRenderer(blobs: FlakyBlobs(blobs: notebookStore, failures: failures)).renderPDF(
        documentID: "doc", index: notebookIndex, to: folder.appending(path: "notebook.pdf")
    )
    let (index, store) = document(try annotated())
    for (name, overlay) in [("overlay.pdf", true), ("redraw.pdf", false)] {
        try await AnnotatedPDFRenderer(blobs: FlakyBlobs(blobs: store, failures: failures)).renderPDF(
            documentID: "doc", index: index, to: folder.appending(path: name), allowOverlay: overlay
        )
    }
}

private let placeholderRunnerCanBeRestarted = CommandLine.arguments.first?.hasSuffix("swiftpm-testing-helper") == true
    && CommandLine.arguments.contains("--test-bundle-path")

@Test(
    "The other half of the test below: writes the placeholders where the process that started it says",
    .enabled(if: ProcessInfo.processInfo.environment[placeholderOutputKey] != nil)
)
func writePlaceholdersForAnotherProcess() async throws {
    try await writePlaceholders(
        into: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[placeholderOutputKey]))
    )
}

@Test(
    "Placeholders are the same bytes whichever process writes them, and whatever its hash seed",
    .enabled(if: placeholderRunnerCanBeRestarted)
)
func placeholdersAreTheSameInEveryProcess() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-placeholder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let here = folder.appending(path: "here")
    try await writePlaceholders(into: here)

    // The runner started again, asked for the test above alone: twice with
    // a hash seed of its own each time, once with the fixed one.
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
        arguments.removeSubrange(filter...(filter + 1))
    }
    arguments += ["--filter", "writePlaceholdersForAnotherProcess"]
    // A run under a sanitizer carries its runtime beside the test bundle, and
    // a process started from here has to be handed it again.
    var sanitizers: [String] = []
    if let bundle = arguments.firstIndex(of: "--test-bundle-path").map({ arguments[$0 + 1] }) {
        let frameworks = URL(fileURLWithPath: bundle).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        sanitizers = names.filter { $0.hasPrefix("libclang_rt.") && $0.hasSuffix("_osx_dynamic.dylib") }
            .sorted().map { frameworks.appending(path: $0).path }
    }
    var written: [URL] = []
    for (run, deterministic) in [false, false, true].enumerated() {
        let output = folder.appending(path: "process\(run)")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        if deterministic { environment["SWIFT_DETERMINISTIC_HASHING"] = "1" }
        environment[placeholderOutputKey] = output.path
        if !sanitizers.isEmpty { environment["DYLD_INSERT_LIBRARIES"] = sanitizers.joined(separator: ":") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        process.environment = environment
        let log = folder.appending(path: "process\(run).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        try logHandle.close()
        try #require(
            process.terminationStatus == 0,
            "run \(run): \(String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self).suffix(2000))"
        )
        written.append(output)
    }

    // CoreGraphics dates its documents and names them afresh; the rest is
    // the same file.
    for name in placeholderOutputs {
        let expected = InkTesting.normalized(try Data(contentsOf: here.appending(path: name)))
        for (run, output) in written.enumerated() {
            #expect(InkTesting.normalized(try Data(contentsOf: output.appending(path: name))) == expected, "\(name), run \(run)")
        }
    }
}
