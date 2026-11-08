// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import ImageIO
import RMLines
@testable import RMRender
import Synchronization
import Testing

// A render fetches each of a document's files once. A PDF export measures
// every page before it draws the first and parses each again when it draws
// it; what these guard is that the second parse reads the bytes the
// measuring kept (`PageSpool`) rather than asking `PageBlobs` again — on
// every route, with pages whose bytes do not arrive and pages that do not
// parse among them, and when the render is cancelled — that what is drawn is
// what fetching every page again drew, and that the spool holds what it
// promises and leaves nothing behind.

// MARK: - Fixtures

/// Every fetch, by blob name.
private final class FetchTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func note(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var all: [String: Int] { lock.withLock { counts } }
    func reset() { lock.withLock { counts.removeAll() } }
}

/// Blobs out of a dictionary, by name, every fetch counted. A name in
/// `failing` never arrives; a name in `hanging` waits for the render to be
/// cancelled.
private struct TalliedBlobs: PageBlobs {
    let files: [String: Data]
    let tally: FetchTally
    var failing: Set<String> = []
    var hanging: Set<String> = []
    var started: Latch?

    struct Unreachable: Error {}

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        tally.note(name)
        if failing.contains(name) { throw Unreachable() }
        if hanging.contains(name) {
            started?.open()
            try await Task.sleep(for: .seconds(60))
        }
        guard let bytes = files[name] else { throw RenderError.malformedPage(name) }
        return bytes
    }

    func file(
        hash: String, name: String, owner: String?, size: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        tally.note(name)
        let url = FileManager.default.temporaryDirectory.appending(path: "rmrender-once-\(UUID().uuidString).blob")
        try files[name]?.write(to: url)
        return BlobFile(url: url, isTemporary: true)
    }
}

private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    var opened: Bool { lock.withLock { isOpen } }
}

private func index(_ files: [String: Data]) -> DocumentFiles {
    DocumentFiles(files: files.keys.sorted().map { DocumentFile(hash: $0, name: $0, size: Int64(files[$0]?.count ?? 0)) })
}

private let author = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))

/// A page of strokes, with typed text when `typed`, and the picture when
/// `picture`: each page in words of its own, so no two pages share bytes.
private func page(_ seed: Int, typed: Bool = false, picture: Bool = false) throws -> Data {
    let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
    let paragraphs: [RMPageDraft.Paragraph] = typed
        ? [.init("Page \(seed) \(words[seed % words.count])", style: 2), .init(words.shuffled(seed: seed), style: 1)]
        : []
    let stroke = RMPageDraft.Stroke(
        tool: .fineliner2, color: .black,
        points: (0..<16).map { RMPageDraft.Point(x: Float(-500 + $0 * 40 + seed), y: Float(300 + seed * 9 + $0 * 7)) }
    )
    let images: [RMPageDraft.Image] = picture
        ? [.init(file: "picture.png", key: (0..<16).map { UInt8($0) }, x: -200, y: 1200, width: 300, height: 200)]
        : []
    return try RMWriter.page(
        RMPageDraft(
            author: author,
            sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
            column: .init(.medium), paragraphs: paragraphs, strokes: [stroke], images: images
        )
    )
}

private extension Array where Element == String {
    func shuffled(seed: Int) -> String {
        indices.map { self[($0 * 5 + seed) % count] }.joined(separator: " ")
    }
}

private func picture() -> Data {
    let size = 8
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for index in 0..<(size * size) {
        pixels[index * 4] = UInt8(index * 4 % 256)
        pixels[index * 4 + 1] = 120
        pixels[index * 4 + 2] = UInt8(255 - index * 3 % 256)
        pixels[index * 4 + 3] = 255
    }
    let data = NSMutableData()
    guard let context = CGContext(
        data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ), let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func cPages(_ ids: [String], redirs: Bool) -> Data {
    let records = ids.enumerated().map { position, id in
        redirs
            ? #"{"id": "\#(id)", "redir": {"timestamp": "1:2", "value": \#(position)}}"#
            : #"{"id": "\#(id)", "template": {"timestamp": "1:2", "value": "Isometric"}}"#
    }
    return Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(records.joined(separator: ", "))]}}"#.utf8)
}

/// The pages of the fixture documents: typed text on every third, the
/// picture on every fifth, page 3 torn and page 5 never written on.
private let fixturePages = 24
private let torn = 3
private let unwritten = 5
/// The page whose bytes do not arrive, where a test asks for one.
private let lost = 7

private func notebook() throws -> [String: Data] {
    var files: [String: Data] = ["doc/p0/picture.png": picture()]
    for position in 0..<fixturePages where position != unwritten {
        files["doc/p\(position).rm"] = position == torn
            ? Data("not a page".utf8)
            : try page(position, typed: position.isMultiple(of: 3), picture: position.isMultiple(of: 5))
    }
    files["doc.content"] = cPages((0..<fixturePages).map { "p\($0)" }, redirs: false)
    return files
}

/// An annotated document over an original of as many pages. `brokenPage`
/// gives that page of the original resources the file does not have: the
/// overlay, which reads them, declines when it comes to it, and the document
/// is redrawn — after the overlay has drawn the pages before it.
private func annotated(brokenPage: Int? = nil) throws -> [String: Data] {
    var files: [String: Data] = ["doc/p0/picture.png": picture()]
    for position in 0..<fixturePages where position != unwritten {
        files["doc/p\(position).rm"] = position == torn
            ? Data("not a page".utf8)
            : try page(position, typed: position.isMultiple(of: 3), picture: position.isMultiple(of: 5))
    }
    files["doc.content"] = cPages((0..<fixturePages).map { "p\($0)" }, redirs: true)
    files["doc.pdf"] = handMadePDF(pages: fixturePages, brokenPage: brokenPage)
    return files
}

/// A PDF of `pages` pages written by hand, so that one page can name
/// resources the file has no object for.
private func handMadePDF(pages: Int, brokenPage: Int?) -> Data {
    var objects: [String] = []
    let kids = (0..<pages).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
    objects.append("<< /Type /Catalog /Pages 2 0 R >>")
    objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>")
    for position in 0..<pages {
        let content = 4 + position * 2
        let resources = position == brokenPage ? "/Resources 999 0 R" : "/Resources << >>"
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] \(resources) /Contents \(content) 0 R >>")
        let stream = "0.6 g \(20 + position) 20 40 40 re f"
        objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
    }
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (number, object) in objects.enumerated() {
        offsets.append(out.utf8.count)
        out += "\(number + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(out.utf8)
}

/// Every small file of `files` a render reads — `.content`, the pages that
/// have bytes, the picture — fetched exactly once, and nothing else asked
/// for more than once.
private func expectEachFetchedOnce(
    _ tally: FetchTally, _ files: [String: Data], skipping skipped: Set<String> = [],
    _ route: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    for name in files.keys.sorted() where !skipped.contains(name) {
        #expect(tally.count(name) == 1, "\(route): \(name) fetched \(tally.count(name)) times", sourceLocation: sourceLocation)
    }
    for (name, count) in tally.all where count > 1 {
        Issue.record("\(route): \(name) fetched \(count) times", sourceLocation: sourceLocation)
    }
}

private func temporaryPDF() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rmrender-once-\(UUID().uuidString).pdf")
}

/// What the spool's files are called in the temporary directory, to see
/// none is left behind.
private func spoolFiles() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
    return Set(names.filter { $0.hasPrefix(".rmrender-spool-") })
}

// MARK: - Notebooks

@Test("Every route of a notebook fetches each page once, whatever is asked of unfetched pages",
      arguments: [UnfetchedPagePolicy.placeholder, .blank], [false, true])
func notebookFetchesEachPageOnce(_ policy: UnfetchedPagePolicy, losing: Bool) async throws {
    let files = try notebook()
    let tally = FetchTally()
    let blobs = TalliedBlobs(files: files, tally: tally, failing: losing ? ["doc/p\(lost).rm"] : [])
    let renderer = NotebookRenderer(blobs: blobs)
    let documentIndex = index(files)

    _ = try await renderer.renderPDF(documentID: "doc", index: documentIndex, unfetchedPages: policy)
    expectEachFetchedOnce(tally, files, "PDF as data")

    tally.reset()
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    try await renderer.renderPDF(documentID: "doc", index: documentIndex, to: output, unfetchedPages: policy)
    expectEachFetchedOnce(tally, files, "PDF to a file")

    tally.reset()
    _ = try await renderer.renderImages(documentID: "doc", index: documentIndex, scale: 0.25, unfetchedPages: policy)
    expectEachFetchedOnce(tally, files, "bitmaps")

    tally.reset()
    _ = try await renderer.renderInkImages(documentID: "doc", index: documentIndex, scale: 0.25, pages: [0, 1])
    expectEachFetchedOnce(tally, files, "handwriting alone")
}

@Test("Strict: a notebook fetches each page at most once on its way to the error")
func strictNotebookFetchesEachPageOnce() async throws {
    let files = try notebook()
    let tally = FetchTally()
    let renderer = NotebookRenderer(blobs: TalliedBlobs(files: files, tally: tally, failing: ["doc/p\(lost).rm"]))
    await #expect(throws: PageFetchError.self) {
        _ = try await renderer.renderPDF(documentID: "doc", index: index(files), unfetchedPages: .strict)
    }
    #expect(tally.all.values.allSatisfy { $0 == 1 }, "\(tally.all.filter { $0.value > 1 })")
}

@Test("A notebook drawn out of the spool is the notebook drawn by fetching every page again, to the byte")
func notebookSpoolDrawsTheSameBytes() async throws {
    let files = try notebook()
    let documentIndex = index(files)
    func render(_ spooling: PageSpool.Configuration?) async throws -> Data {
        try await NotebookRenderer(blobs: TalliedBlobs(files: files, tally: FetchTally()), spooling: spooling)
            .renderPDF(documentID: "doc", index: documentIndex)
    }
    let refetched = try await render(nil)
    // Held in memory, all of it; and nothing in memory, all of it in the file.
    for spooling in [PageSpool.Configuration.standard, .init(memoryBudget: 0, directory: FileManager.default.temporaryDirectory)] {
        let spooled = try await render(spooling)
        #expect(InkTesting.normalized(spooled) == InkTesting.normalized(refetched))
    }
}

// MARK: - Annotated documents

@Test("An annotated document fetches each page once, overlaid or redrawn, whatever is asked of unfetched pages",
      arguments: [UnfetchedPagePolicy.placeholder, .blank], [false, true])
func annotatedFetchesEachPageOnce(_ policy: UnfetchedPagePolicy, losing: Bool) async throws {
    let files = try annotated()
    let tally = FetchTally()
    let renderer = AnnotatedPDFRenderer(
        blobs: TalliedBlobs(files: files, tally: tally, failing: losing ? ["doc/p\(lost).rm"] : [])
    )
    for overlay in [true, false] {
        tally.reset()
        let output = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: output) }
        try await renderer.renderPDF(
            documentID: "doc", index: index(files), to: output, allowOverlay: overlay, unfetchedPages: policy
        )
        expectEachFetchedOnce(tally, files, overlay ? "overlay" : "redraw")
    }
}

@Test("An overlay that declines part of the way through and is redrawn still fetches each page once")
func declinedOverlayFetchesEachPageOnce() async throws {
    let files = try annotated(brokenPage: 20)
    let tally = FetchTally()
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    try await AnnotatedPDFRenderer(blobs: TalliedBlobs(files: files, tally: tally))
        .renderPDF(documentID: "doc", index: index(files), to: output)
    expectEachFetchedOnce(tally, files, "overlay, then redraw")
    // Redrawn, not overlaid: the output does not begin with the original.
    let original = try #require(files["doc.pdf"])
    #expect(try Data(contentsOf: output).prefix(original.count) != original)

    // What the spool saves: without it, the pages the overlay drew before it
    // declined are fetched three times — measured, overlaid, redrawn.
    tally.reset()
    try await AnnotatedPDFRenderer(
        blobs: TalliedBlobs(files: files, tally: tally), nativeRunPages: AnnotatedPDFRenderer.nativeRunPages,
        spooling: nil
    ).renderPDF(documentID: "doc", index: index(files), to: output)
    #expect(tally.count("doc/p0.rm") == 3)
}

@Test("An annotated document drawn out of the spool is the one drawn by fetching every page again, to the byte",
      arguments: [true, false])
func annotatedSpoolDrawsTheSameBytes(overlay: Bool) async throws {
    let files = try annotated()
    let documentIndex = index(files)
    func render(_ spooling: PageSpool.Configuration?) async throws -> Data {
        let output = temporaryPDF()
        defer { try? FileManager.default.removeItem(at: output) }
        try await AnnotatedPDFRenderer(
            blobs: TalliedBlobs(files: files, tally: FetchTally()), nativeRunPages: AnnotatedPDFRenderer.nativeRunPages,
            spooling: spooling
        ).renderPDF(documentID: "doc", index: documentIndex, to: output, allowOverlay: overlay)
        return try Data(contentsOf: output)
    }
    let refetched = try await render(nil)
    for spooling in [PageSpool.Configuration.standard, .init(memoryBudget: 0, directory: FileManager.default.temporaryDirectory)] {
        let spooled = try await render(spooling)
        #expect(InkTesting.normalized(spooled) == InkTesting.normalized(refetched))
    }
}

// MARK: - Cancellation

@Test("A render cancelled while it measures fetches no page twice and leaves no spool behind",
      arguments: [0, 1, 2])
func cancelledRenderFetchesOnce(route: Int) async throws {
    let before = spoolFiles()
    let notebookRoute = route == 0
    let files = notebookRoute ? try notebook() : try annotated()
    let tally = FetchTally()
    let started = Latch()
    // The last page hangs until the render is cancelled; every other page
    // has been fetched — and, the budget being nothing, spooled to a file —
    // by then.
    let blobs = TalliedBlobs(
        files: files, tally: tally, hanging: ["doc/p\(fixturePages - 1).rm"], started: started
    )
    let spooling = PageSpool.Configuration(memoryBudget: 0, directory: FileManager.default.temporaryDirectory)
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    let render = Task {
        if notebookRoute {
            try await NotebookRenderer(blobs: blobs, spooling: spooling)
                .renderPDF(documentID: "doc", index: index(files), to: output)
        } else {
            try await AnnotatedPDFRenderer(
                blobs: blobs, nativeRunPages: AnnotatedPDFRenderer.nativeRunPages, spooling: spooling
            ).renderPDF(documentID: "doc", index: index(files), to: output, allowOverlay: route == 1)
        }
    }
    while !started.opened { await Task.yield() }
    render.cancel()
    await #expect(throws: (any Error).self) { try await render.value }
    #expect(tally.all.values.allSatisfy { $0 == 1 }, "\(tally.all.filter { $0.value > 1 })")
    #expect(!FileManager.default.fileExists(atPath: output.path))
    // The spool's file was unlinked as it was opened: nothing new by its
    // name, whatever became of the render.
    #expect(spoolFiles().subtracting(before).isEmpty)
}

@Test("A redraw cancelled while it draws out of the spool stops, fetches nothing again, and leaves nothing")
func redrawCancelledWhileDrawingStops() async throws {
    let before = spoolFiles()
    let files = try annotated()
    let tally = FetchTally()
    let originalBytes = Int64(try #require(files["doc.pdf"]).count)
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    let spooling = PageSpool.Configuration(memoryBudget: 0, directory: FileManager.default.temporaryDirectory)
    await #expect(throws: CancellationError.self) {
        try await AnnotatedPDFRenderer(
            blobs: TalliedBlobs(files: files, tally: tally), nativeRunPages: AnnotatedPDFRenderer.nativeRunPages,
            spooling: spooling
        ).renderPDF(
            documentID: "doc", index: index(files), to: output, allowOverlay: false,
            onProgress: { completed, _ in
                // Told from inside the drawing, a page at a time: the task
                // cancelled is the one drawing, as a caller's cancel reaches it.
                if completed == originalBytes + 6 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        )
    }
    #expect(tally.all.values.allSatisfy { $0 == 1 }, "\(tally.all.filter { $0.value > 1 })")
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(spoolFiles().subtracting(before).isEmpty)
}

// MARK: - Pages that arrive once

/// Blobs whose every page answers the first fetch and none after it — a
/// cache emptied, a connection dropped, once the page has been measured.
private struct OnceBlobs: PageBlobs {
    let files: [String: Data]
    let tally: FetchTally

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        tally.note(name)
        guard tally.count(name) == 1 || !name.hasSuffix(".rm") else { throw TalliedBlobs.Unreachable() }
        guard let bytes = files[name] else { throw RenderError.malformedPage(name) }
        return bytes
    }

    func file(
        hash: String, name: String, owner: String?, size: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        let url = FileManager.default.temporaryDirectory.appending(path: "rmrender-once-\(UUID().uuidString).blob")
        try files[name]?.write(to: url)
        return BlobFile(url: url, isTemporary: true)
    }
}

@Test("A page that arrives for the measuring and never again is drawn whole, and nothing is told unfetched")
func pagesThatArriveOnceAreDrawn() async throws {
    let files = try notebook()
    let tallies = FetchTally()
    let pdf = try await NotebookRenderer(blobs: OnceBlobs(files: files, tally: FetchTally())).renderPDF(
        documentID: "doc", index: index(files), unfetchedPages: .strict, onUnfetched: { _ in tallies.note("unfetched") }
    )
    let reference = try await NotebookRenderer(blobs: TalliedBlobs(files: files, tally: FetchTally()))
        .renderPDF(documentID: "doc", index: index(files))
    #expect(InkTesting.normalized(pdf) == InkTesting.normalized(reference))

    let annotatedFiles = try annotated()
    for overlay in [true, false] {
        let output = temporaryPDF(), expected = temporaryPDF()
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: expected)
        }
        try await AnnotatedPDFRenderer(blobs: OnceBlobs(files: annotatedFiles, tally: FetchTally())).renderPDF(
            documentID: "doc", index: index(annotatedFiles), to: output, allowOverlay: overlay,
            unfetchedPages: .strict, onUnfetched: { _ in tallies.note("unfetched") }
        )
        try await AnnotatedPDFRenderer(blobs: TalliedBlobs(files: annotatedFiles, tally: FetchTally())).renderPDF(
            documentID: "doc", index: index(annotatedFiles), to: expected, allowOverlay: overlay
        )
        #expect(InkTesting.normalized(try Data(contentsOf: output)) == InkTesting.normalized(try Data(contentsOf: expected)))
    }
    #expect(tallies.count("unfetched") == 0)
}

// MARK: - The spool

@Test("The spool hands back what it was given, out of memory and out of its file alike")
func spoolKeepsTheBytes() throws {
    let before = spoolFiles()
    let spool = PageSpool(.init(memoryBudget: 100, directory: FileManager.default.temporaryDirectory))
    let pages: [Data] = (0..<40).map { (position: Int) -> Data in
        let bytes: [UInt8] = (0..<(30 + position * 7)).map { (offset: Int) -> UInt8 in UInt8((offset + position) % 251) }
        return Data(bytes)
    }
    DispatchQueue.concurrentPerform(iterations: pages.count) { position in
        spool.put(pages[position], at: position)
    }
    let footprint = spool.footprint
    #expect(footprint.memory <= 100)
    #expect(footprint.file > 0)
    let total: Int = pages.reduce(0) { $0 + $1.count }
    #expect(Int64(footprint.memory) + footprint.file == Int64(total))
    let mismatches = Mutex<[Int]>([])
    DispatchQueue.concurrentPerform(iterations: pages.count) { position in
        if spool.data(at: position) != pages[position] { mismatches.withLock { $0.append(position) } }
    }
    #expect(mismatches.withLock { $0 }.isEmpty)
    #expect(spool.data(at: pages.count) == nil)
    #expect(spoolFiles().subtracting(before).isEmpty)
}

@Test("A spool given far more than its budget holds no more than the budget, and the rest in its file")
func spoolStaysWithinItsBudget() {
    // Two thousand pages of 64 KB, the size of a page written full: 125 MB
    // through a spool of the standard budget. Made from their number, so
    // the test holds none of them itself.
    func bytes(_ position: Int) -> Data {
        var data = Data(repeating: UInt8(truncatingIfNeeded: position &* 31), count: 64 << 10)
        withUnsafeBytes(of: UInt64(position).littleEndian) { data.replaceSubrange(0..<8, with: $0) }
        return data
    }
    let budget = PageSpool.Configuration.standard.memoryBudget
    let spool = PageSpool()
    DispatchQueue.concurrentPerform(iterations: 2000) { spool.put(bytes($0), at: $0) }
    let footprint = spool.footprint
    #expect(footprint.memory <= budget)
    #expect(Int64(footprint.memory) + footprint.file == 2000 * (64 << 10))
    let mismatches = Mutex<[Int]>([])
    DispatchQueue.concurrentPerform(iterations: 2000) { position in
        if spool.data(at: position) != bytes(position) { mismatches.withLock { $0.append(position) } }
    }
    #expect(mismatches.withLock { $0 }.isEmpty)
}

@Test("A notebook of two thousand pages fetches each once from a source with no cache")
func longNotebookFetchesEachPageOnce() async throws {
    let pages = 2000
    var files: [String: Data] = [:]
    for position in 0..<pages {
        files["doc/p\(position).rm"] = makePage(points: (0...6).map {
            StrokeSample(x: Float(-500 + $0 * 90 + position % 50), y: Float(200 + position % 400 + $0 * 9), width: 20)
        })
    }
    files["doc.content"] = cPages((0..<pages).map { "p\($0)" }, redirs: false)
    let tally = FetchTally()
    // A budget of a few pages: most of the book goes through the file.
    let renderer = NotebookRenderer(
        blobs: TalliedBlobs(files: files, tally: tally),
        spooling: .init(memoryBudget: 16 << 10, directory: FileManager.default.temporaryDirectory)
    )
    let output = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: output) }
    try await renderer.renderPDF(documentID: "doc", index: index(files), to: output)
    expectEachFetchedOnce(tally, files, "two thousand pages")
    #expect(try #require(CGPDFDocument(output as CFURL)).numberOfPages == pages)
}

@Test("A spool whose file will not open keeps what fits in memory, and the drawing fetches the rest again")
func spoolWithoutAFileFallsBack() async throws {
    let spool = PageSpool(.init(memoryBudget: 10, directory: URL(fileURLWithPath: "/dev/null/no-such-folder")))
    spool.put(Data([1, 2, 3]), at: 0)
    spool.put(Data(repeating: 9, count: 64), at: 1)
    #expect(spool.data(at: 0) == Data([1, 2, 3]))
    #expect(spool.data(at: 1) == nil)

    // A render whose spool cannot keep a page fetches each again to draw it,
    // and draws the same document.
    let files = try notebook()
    let tally = FetchTally()
    let pdf = try await NotebookRenderer(
        blobs: TalliedBlobs(files: files, tally: tally),
        spooling: .init(memoryBudget: 0, directory: URL(fileURLWithPath: "/dev/null/no-such-folder"))
    ).renderPDF(documentID: "doc", index: index(files))
    #expect(tally.count("doc/p0.rm") == 2)
    let spooled = try await NotebookRenderer(blobs: TalliedBlobs(files: files, tally: FetchTally()))
        .renderPDF(documentID: "doc", index: index(files))
    #expect(InkTesting.normalized(pdf) == InkTesting.normalized(spooled))
}
