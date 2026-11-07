// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import RMRender
import RMLines
import Synchronization
import Testing

// The native Forms of an overlay drawn a run of pages at a time, into one PDF
// (`NativeBatch`), so that a typeface is embedded once a run rather than once
// a page. What these guard: that a page drawn in a run paints what it painted
// drawn alone, that the faces really are shared, that the document is cut
// into runs the same way every time and in every process, and that the
// writer keeps its order, its failures, its cancellation and its window
// when its unit of work is a run.

// MARK: - Fixtures

/// A document of `count` pages over an original of as many: typed text on
/// most of them, each page in letters of its own so that no two pages cut a
/// face alike; a picture now and then, pencil and an eraser on some, and a
/// page of strokes alone — which the overlay writes with its own operators —
/// on every third.
private func batchDocument(pages count: Int) throws -> [String: Data] {
    var random = SplitMix64(seed: 0xBA7C)
    func below(_ bound: Int) -> Int { Int(random.next() % UInt64(bound)) }
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzàáâäåæçèéêëìíîïñòóôöøùúûüýąćęłńśźżčěřšžαβγδεζηθικλμνξπρστφχψωабвгдежзиклмнопрстуфхцчшщыэюя")
    func words(_ count: Int) -> String {
        let base = below(alphabet.count)
        return (0..<count).map { _ in
            String((0..<(3 + below(5))).map { _ in alphabet[(base + below(24)) % alphabet.count] })
        }.joined(separator: " ")
    }

    var files: [String: Data] = ["doc.pdf": try originalPDF(pages: count), "doc/p0/picture.png": batchPicture()]
    var records: [String] = []
    for index in 0..<count {
        let strokesAlone = index % 3 == 2
        let paragraphs: [RMPageDraft.Paragraph] = strokesAlone ? [] : [
            .init(words(3), style: 2), .init(words(30), style: 1), .init(words(8), style: 1, bold: true),
            .init(words(8), style: 1, italic: true),
        ]
        let tools: [PenTool] = strokesAlone
            ? [.fineliner2, .ballpoint2, .marker2]
            : [.fineliner2, .pencil2, .mechanicalPencil2, .shader, .ballpoint1] + (index.isMultiple(of: 4) ? [.eraser] : [])
        let strokes = (0..<(4 + below(6))).map { _ in
            var x = Double(-500 + below(900)), y = Double(100 + below(1600))
            let points = (0..<(4 + below(16))).map { _ in
                x += Double(below(18)) - 4
                y += Double(below(24)) - 12
                return RMPageDraft.Point(
                    x: Float(x), y: Float(y), speed: UInt16(below(200)), width: UInt16(8 + below(80)),
                    direction: UInt8(below(256)), pressure: UInt8(below(256))
                )
            }
            let tool = tools[below(tools.count)]
            return RMPageDraft.Stroke(
                tool: tool, color: .black, argb: tool == .shader ? 0x4000_00FF : nil, thickness: 2, points: points
            )
        }
        let images: [RMPageDraft.Image] = !strokesAlone && index.isMultiple(of: 5)
            ? [.init(file: "picture.png", key: (0..<16).map { UInt8($0) }, x: -200, y: 1200, width: 300, height: 200)]
            : []
        files["doc/p\(index).rm"] = try RMWriter.page(
            RMPageDraft(
                author: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)),
                sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
                column: .init(.medium), paragraphs: paragraphs, strokes: strokes, images: images
            )
        )
        records.append(#"{"id": "p\#(index)", "redir": {"timestamp": "1:2", "value": \#(index)}}"#)
    }
    files["doc.content"] = Data(#"{"formatVersion": 2, "cPages": {"pages": [\#(records.joined(separator: ", "))]}}"#.utf8)
    return files
}

private func originalPDF(pages: Int) throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for page in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)
        context.fill(CGRect(x: 40 + Double(page), y: 60, width: 300, height: 200))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// A small opaque picture.
private func batchPicture() -> Data {
    let size = 16
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for index in 0..<(size * size) {
        pixels[index * 4] = UInt8(index % 256)
        pixels[index * 4 + 1] = UInt8((index * 5) % 256)
        pixels[index * 4 + 2] = 90
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

/// Blobs out of a dictionary, by name; the original written to `folder`.
private struct BatchBlobs: PageBlobs {
    let files: [String: Data]
    let folder: URL

    func data(hash: String, name: String, owner: String?) async throws -> Data {
        guard let bytes = files[name] else { throw RenderError.malformedPage(name) }
        return bytes
    }

    func file(
        hash: String, name: String, owner: String?, size: Int64, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        let url = folder.appending(path: "\(UUID().uuidString)-" + name.replacingOccurrences(of: "/", with: "_"))
        try files[name]?.write(to: url)
        return BlobFile(url: url, isTemporary: true)
    }
}

/// `files` overlaid onto their original, with native Forms drawn in runs of
/// `runPages` — one draws each alone, as a PDF of its own.
private func overlaid(_ files: [String: Data], runPages: Int, in folder: URL, name: String) async throws -> Data {
    let index = DocumentFiles(files: files.map { DocumentFile(hash: $0.key, name: $0.key, size: Int64($0.value.count)) })
    let output = folder.appending(path: name)
    try await AnnotatedPDFRenderer(blobs: BatchBlobs(files: files, folder: folder), nativeRunPages: runPages)
        .renderPDF(documentID: "doc", index: index, to: output)
    return try Data(contentsOf: output)
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "rmrender-batch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// The font programs a PDF carries, by object, and the faces they cut —
/// the `/FontName`s without their subset tag.
private func fontPrograms(of pdf: Data) throws -> (programs: Set<Int>, faces: Set<String>) {
    let file = try PDFFile(bytes: pdf)
    var programs: Set<Int> = []
    var faces: Set<String> = []
    for number in file.offsets.keys {
        guard let dictionary = try? file.object(number).dictionaryValue,
              dictionary["Type"]?.nameValue == "FontDescriptor" else { continue }
        for key in ["FontFile", "FontFile2", "FontFile3"] {
            if case .reference(let program, _)? = dictionary[key] { programs.insert(program) }
        }
        if let name = dictionary["FontName"]?.nameValue {
            faces.insert(String(name.split(separator: "+").last ?? Substring(name)))
        }
    }
    return (programs, faces)
}

// MARK: - Drawing in runs

/// Two windows of runs and a little: the runs cut at a page index, a run
/// beginning and ending on stroke-only pages, and a last short one.
private let batchPages = 70

@Test("A page drawn in a run paints what it painted drawn alone")
func runsPaintAsPagesAlone() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = try batchDocument(pages: batchPages)
    let alone = try await overlaid(files, runPages: 1, in: folder, name: "alone.pdf")
    let batched = try await overlaid(files, runPages: AnnotatedPDFRenderer.nativeRunPages, in: folder, name: "batched.pdf")
    #expect(alone != batched)
    for page in 1...batchPages {
        #expect(try InkTesting.differingPixels(alone, batched, page: page, scale: 1.5) == 0, "page \(page)")
    }
}

@Test("A face is embedded once a run, not once a page")
func facesAreEmbeddedOnceARun() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = try batchDocument(pages: batchPages)
    let alone = try fontPrograms(of: try await overlaid(files, runPages: 1, in: folder, name: "alone.pdf"))
    let batched = try fontPrograms(
        of: try await overlaid(files, runPages: AnnotatedPDFRenderer.nativeRunPages, in: folder, name: "batched.pdf")
    )
    let runs = (batchPages + AnnotatedPDFRenderer.nativeRunPages - 1) / AnnotatedPDFRenderer.nativeRunPages
    #expect(batched.faces == alone.faces)
    #expect(!batched.faces.isEmpty)
    // CoreGraphics embeds a face as simple TrueType fonts: one cut for the
    // letters of Mac Roman, one for the rest — this text has Greek and
    // Cyrillic in it. So two cuts a face a run at most; drawn alone, every
    // page of text cuts its own of every face it sets.
    #expect(batched.programs.count <= batched.faces.count * runs * 2, "\(batched.programs.count) programs")
    #expect(alone.programs.count >= batchPages * 2 / 3, "\(alone.programs.count) programs")
    #expect(batched.programs.count * 4 <= alone.programs.count, "\(batched.programs.count) of \(alone.programs.count)")
}

@Test("A document is cut into runs by page index and by which pages set type")
func overlayUnitsCut() {
    let typed: Set<Int> = [1, 3, 33, 70, 71]
    let marked = [0, 1, 2, 3, 4, 31, 32, 33, 34, 40, 64, 70, 71, 95, 96]
    let units = AnnotatedPDFRenderer.overlayUnits(marked, runPages: 32) { typed.contains($0) }
    #expect(units == [[0], [1, 2, 3], [4], [31], [32], [33], [34], [40], [64], [70, 71], [95], [96]])
    // Every page once, in order, and no run reaching past its window.
    #expect(units.flatMap { $0 } == marked)
    #expect(units.allSatisfy { ($0.first ?? 0) / 32 == ($0.last ?? 0) / 32 })
    // A run of one is a page at a time, as is a document without type.
    #expect(AnnotatedPDFRenderer.overlayUnits(marked, runPages: 1) { typed.contains($0) } == marked.map { [$0] })
    #expect(AnnotatedPDFRenderer.overlayUnits(marked) { _ in false } == marked.map { [$0] })
    #expect(AnnotatedPDFRenderer.overlayUnits([]) { _ in true }.isEmpty)
}

@Test("A page on which sharing the document would resize a mask is refused, and drawn alone")
func batchRefusesAResizedMask() throws {
    let digest = SHA256.hash(data: Data("the same bytes".utf8))
    let box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let batch = NativeBatch()
    let first = try batch.page(mediaBox: box, ink: nil) { _, masks in
        _ = masks.dimensions(of: digest, width: 30, height: 16)
    }
    let resized = try batch.page(mediaBox: box, ink: nil) { _, masks in
        _ = masks.dimensions(of: digest, width: 26, height: 16)
    }
    let same = try batch.page(mediaBox: box, ink: nil) { _, masks in
        _ = masks.dimensions(of: digest, width: 30, height: 16)
    }
    #expect(first == 0)
    #expect(resized == nil)
    #expect(same == 2)
    let url = try #require(try batch.finish())
    #expect(try PDFFile(url: url).pages().count == 3)
    // Read once, the file is gone.
    let overlays = [0, 1, 2].map { PDFOverlayWriter.Overlay(pageIndex: $0, content: Data(), states: []) }
    _ = try PDFOverlayWriter().prepare(PDFOverlayWriter.OverlayBatch(overlays: overlays, drawingPages: [0, nil, 2], drawing: url))
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // The written ink is asked the same, before it is appended.
    let ledger = InkMaskLedger()
    _ = ledger.dimensions(of: digest, width: 30, height: 16)
    #expect(ledger.wouldResize([InkStream.Mask(digest: digest, width: 26, height: 16, deflated: [])]))
    #expect(!ledger.wouldResize([InkStream.Mask(digest: digest, width: 30, height: 16, deflated: [])]))
    #expect(ledger.resized == 0)
}

// MARK: - The writer, a run at a time

private func plainOriginal(pages: Int, in folder: URL) throws -> (url: URL, file: PDFFile, pages: [PDFFile.Page]) {
    let url = folder.appending(path: "original.pdf")
    try originalPDF(pages: pages).write(to: url)
    let file = try PDFFile(url: url)
    return (url, file, try file.pages())
}

private func plainOverlay(_ page: Int) -> PDFOverlayWriter.Overlay {
    PDFOverlayWriter.Overlay(
        pageIndex: page, content: Data("0 0 1 rg \(10 + page) 10 50 50 re f\n".utf8),
        states: [PDFOverlayWriter.GraphicsState(name: "RMGs0", blendMode: "Multiply", alpha: 0.5)]
    )
}

private struct Failed: Error {}

@Test("Runs of pages make the file a page at a time makes")
func runsKeepTheOrder() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try plainOriginal(pages: 12, in: folder)
    let units = [[0, 1], [2], [3, 4, 5, 6], [8], [9, 10, 11]]
    let sequential = folder.appending(path: "sequential.pdf"), runs = folder.appending(path: "runs.pdf")
    try PDFOverlayWriter().write(original: original.url, overlays: units.flatMap { $0 }.map(plainOverlay), to: sequential)
    try await PDFOverlayWriter().writeConcurrently(
        file: original.file, pages: original.pages, original: original.url, units: units, to: runs, limit: 2
    ) { unit in
        // The later pages of a run finish first, and the runs out of order.
        try await Task.sleep(for: .milliseconds(5 * (6 - unit.count)))
        return PDFOverlayWriter.OverlayBatch(overlays: unit.map(plainOverlay))
    }
    #expect(try Data(contentsOf: runs) == Data(contentsOf: sequential))
}

@Test("A run that fails, or hands back the wrong pages, fails the write and leaves no output")
func aFailedRunFailsTheWrite() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try plainOriginal(pages: 8, in: folder)
    let output = folder.appending(path: "out.pdf")
    let units = [[0, 1], [2, 3], [4, 5, 6], [7]]
    await #expect(throws: Failed.self) {
        try await PDFOverlayWriter().writeConcurrently(
            file: original.file, pages: original.pages, original: original.url, units: units, to: output
        ) { unit in
            guard unit != [2, 3] else { throw Failed() }
            return PDFOverlayWriter.OverlayBatch(overlays: unit.map(plainOverlay))
        }
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    await #expect(throws: PDFReadError.self) {
        try await PDFOverlayWriter().writeConcurrently(
            file: original.file, pages: original.pages, original: original.url, units: units, to: output
        ) { unit in
            PDFOverlayWriter.OverlayBatch(overlays: unit.dropLast(unit.count > 1 ? 1 : 0).map(plainOverlay))
        }
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    // Nothing of the update is left beside the output either.
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".rmrender-") }
    #expect(left.isEmpty)
}

@Test("A cancelled write of runs ends with the cancellation and leaves no output")
func cancelledRunsLeaveNothing() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try plainOriginal(pages: 8, in: folder)
    let output = folder.appending(path: "out.pdf")
    // Open from the start: it only tells the test that a run has begun.
    let started = Gate()
    await started.open()
    let writing = Task {
        try await PDFOverlayWriter().writeConcurrently(
            file: original.file, pages: original.pages, original: original.url, units: [[0, 1, 2], [3, 4], [5, 6, 7]],
            to: output
        ) { unit in
            await started.stopHere()
            try await Task.sleep(for: .seconds(30))
            return PDFOverlayWriter.OverlayBatch(overlays: unit.map(plainOverlay))
        }
    }
    await started.waitForArrival()
    writing.cancel()
    let result = await writing.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test("A run counts as one against the window, and the window holds")
func runsHoldTheWindow() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try plainOriginal(pages: 12, in: folder)
    let output = folder.appending(path: "out.pdf")
    let units = [[0, 1, 2, 3], [4], [5, 6], [7], [8, 9, 10], [11]]
    // The first run is slow; with a window of three, the fourth unit may not
    // begin before the first has been handed over.
    let firstDone = Mutex(false)
    let early = Mutex(false)
    try await PDFOverlayWriter().writeConcurrently(
        file: original.file, pages: original.pages, original: original.url, units: units, to: output, limit: 3
    ) { unit in
        if unit == [0, 1, 2, 3] {
            try await Task.sleep(for: .milliseconds(200))
            firstDone.withLock { $0 = true }
        } else if unit == [7], !firstDone.withLock({ $0 }) {
            early.withLock { $0 = true }
        }
        return PDFOverlayWriter.OverlayBatch(overlays: unit.map(plainOverlay))
    }
    #expect(!early.withLock { $0 })
    #expect(try PDFFile(url: output).pages().count == 12)
}

/// What a bounded walk held at most: jobs started and not yet consumed, all
/// of them and the heavy ones, measured as each job starts — and what it
/// held while the first job, the slow one, was still in the window.
private final class WindowLedger: Sendable {
    private struct Counts {
        var held = 0, heavyHeld = 0, mostHeld = 0, mostHeavy = 0, mostBeforeFirst = 0
        var firstConsumed = false
    }
    private let counts = Mutex(Counts())

    func started(heavy: Bool) {
        counts.withLock {
            $0.held += 1
            if heavy { $0.heavyHeld += 1 }
            $0.mostHeld = max($0.mostHeld, $0.held)
            $0.mostHeavy = max($0.mostHeavy, $0.heavyHeld)
            if !$0.firstConsumed { $0.mostBeforeFirst = max($0.mostBeforeFirst, $0.held) }
        }
    }

    func consumed(heavy: Bool) {
        counts.withLock {
            $0.held -= 1
            if heavy { $0.heavyHeld -= 1 }
            $0.firstConsumed = true
        }
    }

    var most: Walked {
        counts.withLock { Walked(held: $0.mostHeld, heavy: $0.mostHeavy, beforeFirst: $0.mostBeforeFirst, order: []) }
    }
}

/// What `walk` saw: the most held in all, of the heavy jobs, and before the
/// first job was handed over; and the order the answers were consumed in.
private struct Walked {
    let held: Int
    let heavy: Int
    let beforeFirst: Int
    let order: [Int]
}

/// `jobs` walked with a window of `limit` and `heavyLimit` for the heavy
/// ones, the first job slow so that the window fills behind it; what the
/// walk held at most and the order it consumed the answers in.
private func walk(_ jobs: [Bool], limit: Int, heavyLimit: Int) async throws -> Walked {
    let ledger = WindowLedger()
    var order: [Int] = []
    try await RenderWork.boundedConcurrentForEach(
        Array(jobs.indices), limit: limit, heavy: jobs, heavyLimit: heavyLimit
    ) { index in
        ledger.started(heavy: jobs[index])
        try await Task.sleep(for: .milliseconds(index == 0 ? 150 : 2))
        return index
    } consume: { _, index in
        order.append(index)
        ledger.consumed(heavy: jobs[index])
    }
    let most = ledger.most
    return Walked(held: most.held, heavy: most.heavy, beforeFirst: most.beforeFirst, order: order)
}

@Test("A run counts against the run limit and the window; a page alone against the window only")
func runsCountAgainstBothLimits() async throws {
    // Runs only: the run limit is what holds them.
    let runs = try await walk(Array(repeating: true, count: 12), limit: 8, heavyLimit: 2)
    #expect(runs.heavy == 2)
    #expect(runs.held == 2)
    #expect(runs.order == Array(0..<12))

    // Pages alone only: the run limit has nothing to say, and the window fills.
    let pages = try await walk(Array(repeating: false, count: 12), limit: 8, heavyLimit: 1)
    #expect(pages.held == 8)
    #expect(pages.heavy == 0)
    #expect(pages.order == Array(0..<12))

    // Mixed: two runs fill the run limit, and the pages alone behind them
    // still go on until the window is full — the runs count against it too.
    let mixed = try await walk([true, true, false, false, false, false, false, false, false, false], limit: 5, heavyLimit: 2)
    #expect(mixed.heavy == 2)
    #expect(mixed.held == 5)
    #expect(mixed.order == Array(0..<10))

    // A run that finds the run limit reached waits, and so does what comes
    // after it: the window stays a window over the list. Until the first
    // run is handed over, only the two runs are in it.
    let blocked = try await walk([true, true, true, false, false, false], limit: 8, heavyLimit: 2)
    #expect(blocked.heavy == 2)
    #expect(blocked.beforeFirst == 2)
    #expect(blocked.order == Array(0..<6))
}

@Test("The overlay writer holds no more runs than its run limit, and the same file comes out")
func writerHoldsTheRunLimit() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try plainOriginal(pages: 16, in: folder)
    let units = [[0, 1], [2], [3, 4], [5, 6], [7], [8, 9], [10], [11, 12], [13, 14, 15]]
    let sequential = folder.appending(path: "sequential.pdf"), limited = folder.appending(path: "limited.pdf")
    try PDFOverlayWriter().write(original: original.url, overlays: units.flatMap { $0 }.map(plainOverlay), to: sequential)
    // The first run is slow: with a run limit of two, no other run may begin
    // before it has been handed over — but pages alone may.
    let firstDone = Mutex(false)
    let early = Mutex((runs: 0, pages: 0))
    try await PDFOverlayWriter().writeConcurrently(
        file: original.file, pages: original.pages, original: original.url, units: units, to: limited,
        limit: 8, runLimit: 2
    ) { unit in
        if unit == [0, 1] {
            try await Task.sleep(for: .milliseconds(200))
            firstDone.withLock { $0 = true }
        } else if !firstDone.withLock({ $0 }) {
            early.withLock { unit.count > 1 ? ($0.runs += 1) : ($0.pages += 1) }
        }
        return PDFOverlayWriter.OverlayBatch(overlays: unit.map(plainOverlay))
    }
    #expect(early.withLock { $0.runs } == 1)
    #expect(early.withLock { $0.pages } == 1)
    #expect(try Data(contentsOf: limited) == Data(contentsOf: sequential))
}

// MARK: - The same in every process

/// Where `writeBatchesForAnotherProcess` writes: set only in a process
/// `batchesAreTheSameInEveryProcess` starts.
private let batchOutputKey = "RMRENDER_TEST_BATCH_OUTPUT"

private let batchRunnerCanBeRestarted = CommandLine.arguments.first?.hasSuffix("swiftpm-testing-helper") == true
    && CommandLine.arguments.contains("--test-bundle-path")

private func writeBatches(to output: URL) async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let written = try await overlaid(
        try batchDocument(pages: batchPages), runPages: AnnotatedPDFRenderer.nativeRunPages, in: folder, name: "out.pdf"
    )
    try written.write(to: output)
}

@Test(
    "The other half of the test below: writes the overlay where the process that started it says",
    .enabled(if: ProcessInfo.processInfo.environment[batchOutputKey] != nil)
)
func writeBatchesForAnotherProcess() async throws {
    try await writeBatches(to: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[batchOutputKey])))
}

@Test(
    "An overlay drawn in runs is the same bytes whichever process writes it, and whatever its hash seed",
    .enabled(if: batchRunnerCanBeRestarted)
)
func batchesAreTheSameInEveryProcess() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let here = folder.appending(path: "here.pdf")
    try await writeBatches(to: here)

    // The runner started again, asked for the test above alone: twice with
    // a hash seed of its own each time, once with the fixed one.
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
        arguments.removeSubrange(filter...(filter + 1))
    }
    arguments += ["--filter", "writeBatchesForAnotherProcess"]
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
    let expected = InkTesting.normalized(try Data(contentsOf: here))
    for (run, deterministic) in [false, false, true].enumerated() {
        let output = folder.appending(path: "process\(run).pdf")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        if deterministic { environment["SWIFT_DETERMINISTIC_HASHING"] = "1" }
        environment[batchOutputKey] = output.path
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
        // CoreGraphics dates its documents and names them afresh; the rest
        // is the same file.
        #expect(InkTesting.normalized(try Data(contentsOf: output)) == expected, "run \(run)")
    }
}
