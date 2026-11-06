// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import CoreText
import Foundation
import PDFKit
@testable import RMRender
import Testing

// The overlay written a page at a time. What these guard is that a book's
// worth of marks never has to be in memory at once — each page is asked for
// when its turn comes and is in the file before the next — and that what
// comes out is the same valid incremental update, its mark streams deflated.

/// A PDF of blank pages written by Quartz, with a grey square on each, in a
/// folder of its own: the tests run side by side, and what one leaves behind
/// must not be counted against another.
private func blankDocument(pages: Int, size: CGSize = CGSize(width: 200, height: 300)) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "rmrender-stream-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "original.pdf")
    var box = CGRect(origin: .zero, size: size)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw RenderError.pdfContextUnavailable
    }
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func line(_ page: Int, y: Int = 150) -> PDFOverlayWriter.Overlay {
    PDFOverlayWriter.Overlay(pageIndex: page, content: Data("0 0 0 RG 10 w 20 \(y) m 180 \(y) l S\n".utf8), states: [])
}

/// The dark pixels of one page (counted from one), drawn by CoreGraphics.
private func darkPixels(_ url: URL, page: Int) throws -> Int {
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
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    return stride(from: 0, to: width * height * 4, by: 4).count { Int(buffer[$0]) < 128 }
}

/// The Form XObject `name` among a page's resources (or among those of
/// `inside`, a Form of that page), as stored.
private func form(
    _ name: String,
    of file: PDFFile,
    page: Int,
    inside outer: String? = nil
) throws -> (dictionary: [String: PDFObject], data: Data) {
    var resources = try file.resolve(try file.pages()[page].resources).dictionaryValue
    if let outer {
        let parent = try form(outer, of: file, page: page)
        resources = try file.resolve(parent.dictionary["Resources"]).dictionaryValue
    }
    let objects = try #require(try file.resolve(resources?["XObject"]).dictionaryValue)
    guard case .stream(let dictionary, let data) = try file.resolve(objects[name]) else {
        throw PDFReadError.malformed("no Form \(name)")
    }
    return (dictionary, data)
}

/// Files the writer left behind beside `output`: its temporary copies.
private func leftovers(beside output: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        .filter { $0.hasPrefix(".rmrender-") }
}

@Test("A page at a time: each page is asked for once, in order, and the file is the one a list makes")
func streamingWriteMatchesTheList() throws {
    let original = try blankDocument(pages: 3)
    let listed = original.deletingPathExtension().appendingPathExtension("listed.pdf")
    let streamed = original.deletingPathExtension().appendingPathExtension("streamed.pdf")
    defer {
        try? FileManager.default.removeItem(at: original.deletingLastPathComponent())
    }

    try PDFOverlayWriter().write(original: original, overlays: [line(0), line(2, y: 60)], to: listed)
    let file = try PDFFile(url: original)
    var asked: [Int] = []
    try PDFOverlayWriter().write(
        file: file, pages: try file.pages(), original: original, pageIndices: [0, 2], to: streamed
    ) { page in
        asked.append(page)
        return page == 0 ? line(0) : line(2, y: 60)
    }

    #expect(asked == [0, 2])
    #expect(try Data(contentsOf: streamed) == (try Data(contentsOf: listed)))
    let before = try Data(contentsOf: original)
    let after = try Data(contentsOf: streamed)
    #expect(after.prefix(before.count) == before)
    #expect(try PDFFile(url: streamed).pages().count == 3)
    #expect(PDFDocument(url: streamed)?.pageCount == 3)
    #expect(try darkPixels(streamed, page: 1) > (try darkPixels(original, page: 1)))
    #expect(try darkPixels(streamed, page: 2) == (try darkPixels(original, page: 2)))
    #expect(try darkPixels(streamed, page: 3) > (try darkPixels(original, page: 3)))
}

@Test("A page the original does not have is refused before any page is asked for")
func streamingWriteValidatesFirst() throws {
    let original = try blankDocument(pages: 2)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let file = try PDFFile(url: original)
    var asked = 0
    #expect(throws: PDFOverlayWriter.OverlayError.noSuchPage(5)) {
        try PDFOverlayWriter().write(
            file: file, pages: try file.pages(), original: original, pageIndices: [0, 5], to: output
        ) { page in
            asked += 1
            return line(page)
        }
    }
    #expect(asked == 0)
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try leftovers(beside: output).isEmpty)
}

@Test("A failure half way leaves the destination as it was and no copy behind")
func streamingWriteCleansUpAfterAFailure() throws {
    struct Stop: Error {}
    let original = try blankDocument(pages: 3)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let earlier = Data("what was here before".utf8)
    try earlier.write(to: output)
    let file = try PDFFile(url: original)

    #expect(throws: Stop.self) {
        try PDFOverlayWriter().write(
            file: file, pages: try file.pages(), original: original, pageIndices: [0, 1, 2], to: output
        ) { page in
            guard page < 2 else { throw Stop() }
            return line(page)
        }
    }
    #expect(try Data(contentsOf: output) == earlier)
    #expect(try leftovers(beside: output).isEmpty)

    // An overlay for another page than the one asked for is refused too.
    #expect(throws: PDFReadError.self) {
        try PDFOverlayWriter().write(
            file: file, pages: try file.pages(), original: original, pageIndices: [0], to: output
        ) { _ in line(1) }
    }
    #expect(try Data(contentsOf: output) == earlier)
    #expect(try leftovers(beside: output).isEmpty)
}

@Test("The overlay's mark streams are deflated, and say so")
func overlayStreamsAreDeflated() throws {
    let original = try blankDocument(pages: 1)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    // A one-page PDF of its own, the way the renderer hands over text and
    // pictures: imported as the RMNative Form inside the overlay's.
    let native = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let consumer = try #require(CGDataConsumer(data: native))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 60, y: 200, width: 80, height: 40))
    context.endPDFPage()
    context.closePDF()
    var content = Data("q /RMNative Do Q\n".utf8)
    for step in 0..<200 { content.append(Data("0 0 0 RG 1 w 20 \(step) m 180 \(step) l S\n".utf8)) }

    try PDFOverlayWriter().write(
        original: original,
        overlays: [PDFOverlayWriter.Overlay(pageIndex: 0, content: content, states: [], formPDF: native as Data)],
        to: output
    )

    let file = try PDFFile(url: output)
    let overlay = try form("RMOverlay", of: file, page: 0)
    #expect(overlay.dictionary["Filter"]?.nameValue == "FlateDecode")
    #expect(overlay.dictionary["Length"]?.intValue == overlay.data.count)
    #expect(overlay.data.count < content.count / 4)
    #expect(try file.decode(overlay.dictionary, overlay.data) == content)

    let imported = try form("RMNative", of: file, page: 0, inside: "RMOverlay")
    #expect(imported.dictionary["Filter"]?.nameValue == "FlateDecode")
    #expect(imported.dictionary["Length"]?.intValue == imported.data.count)
    let drawn = try file.decode(imported.dictionary, imported.data)
    #expect(String(decoding: drawn, as: UTF8.self).contains(" re"))

    // Both readers draw what the streams say: the lines and the square.
    #expect(PDFDocument(url: output)?.pageCount == 1)
    #expect(try darkPixels(output, page: 1) > (try darkPixels(original, page: 1)) + 2000)
}

@Test("A deflated stream carries the Adler-32 of what it holds")
func flateChecksumIsAdler32() {
    // The reference value of "Wikipedia" (RFC 1950's checksum, worked
    // through on its own page), and a run long enough to cross the
    // reduction interval more than once.
    let checksum = { (data: Data) in PDFWriter.flate(data).suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    #expect(checksum(Data("Wikipedia".utf8)) == 0x11E6_0398)
    let long = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in long {
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    }
    #expect(checksum(long) == (b << 16 | a))
    #expect(checksum(Data()) == 1)
}

@Test("The cross-reference groups consecutive numbers into runs")
func crossReferenceRuns() {
    let offsets = [1: 10, 2: 20, 3: 30, 7: 70, 8: 80, 10: 100]
    let table = String(decoding: PDFOverlayWriter().crossReferenceTable(offsets, generations: [:]), as: UTF8.self)
    let headers = table.split(separator: "\n").filter { !$0.hasSuffix(" n ") && $0 != "xref" }
    #expect(headers == ["1 3", "7 2", "10 1"])
    #expect(table.contains("0000000070 00000 n \n"))
    #expect(table.split(separator: "\n").count == 1 + 3 + 6)
}

@Test("A book of two thousand marked pages is written as it is drawn")
func aLongBookIsStreamed() throws {
    let pages = 2000
    let original = try blankDocument(pages: pages)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let file = try PDFFile(url: original)
    let originalSize = file.bytes.count
    var random = SplitMix64(seed: 7)
    var written = 0
    var largestCopyAsked = 0
    try PDFOverlayWriter().write(
        file: file, pages: try file.pages(), original: original, pageIndices: Array(0..<pages), to: output
    ) { page in
        // How far the copy beside the output has got when the page is asked
        // for: what is written before the end is what was not held.
        if page == pages - 1 {
            let copy = try #require(try leftovers(beside: output).first)
            let path = output.deletingLastPathComponent().appending(path: copy).path
            largestCopyAsked = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        }
        // A few kilobytes of strokes, every page different.
        var content = Data("0 0 0 RG 1 w\n".utf8)
        for _ in 0..<200 {
            let x = random.next(below: 200), y = random.next(below: 300)
            content.append(Data("\(x) \(y) m \(x + 3) \(y + 2) l S\n".utf8))
        }
        written += content.count
        return PDFOverlayWriter.Overlay(pageIndex: page, content: content, states: [])
    }

    #expect(largestCopyAsked > originalSize + (1 << 20), "the pages were held, not written")
    let size = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
    // Deflated: the whole update, page objects and cross-reference
    // included, under what the operators alone came to as written.
    #expect(size - originalSize < written)
    let reread = try PDFFile(url: output)
    #expect(try reread.pages().count == pages)
    let provider = try #require(CGDataProvider(url: output as CFURL))
    let document = try #require(CGPDFDocument(provider))
    #expect(document.numberOfPages == pages)
    #expect(try darkPixels(output, page: pages) > (try darkPixels(original, page: pages)))
    #expect(try leftovers(beside: output).isEmpty)
}

// MARK: - Pages made side by side

/// A one-page PDF with a line of text and a picture on it: its resources
/// are objects of their own — a font, its descriptor and file, an image —
/// which the overlay copies over and numbers afresh.
private func nativeDrawing(_ seed: Int) throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let text = NSAttributedString(
        string: "page \(seed)",
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
    )
    context.textPosition = CGPoint(x: 20, y: 250)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let pixels = (0..<64).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ seed) }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let picture = try #require(
        CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    )
    context.draw(picture, in: CGRect(x: 40, y: 40, width: 80, height: 80))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// Overlays of every kind the writer takes, a different one on each page:
/// shared and per-page states, stencils under a grown box, native drawings
/// with objects of their own, and plain lines.
private func mixedOverlays(pages: [Int]) throws -> [Int: PDFOverlayWriter.Overlay] {
    var overlays: [Int: PDFOverlayWriter.Overlay] = [:]
    for page in pages {
        switch page % 4 {
        case 0:
            overlays[page] = PDFOverlayWriter.Overlay(
                pageIndex: page,
                content: Data("/RMGs0 gs 0 0 1 RG 8 w 20 \(page) m 180 \(page) l S /RMGs1 gs 20 40 m 180 90 l S\n".utf8),
                states: [
                    .init(name: "RMGs0", blendMode: "Multiply", alpha: 0.5),
                    .init(name: "RMGs1", blendMode: nil, alpha: Double(page % 3 + 1) / 4),
                ]
            )
        case 1:
            let bits = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ page) })
            overlays[page] = PDFOverlayWriter.Overlay(
                pageIndex: page,
                content: Data("0 g q 160 0 0 80 20 100 cm /RMIm0 Do Q\n".utf8),
                states: [],
                images: [.init(name: "RMIm0", width: 16, height: 8, bits: bits)],
                box: CGRect(x: -10, y: -20, width: 230, height: 340)
            )
        case 2:
            overlays[page] = PDFOverlayWriter.Overlay(
                pageIndex: page, content: Data("q /RMNative Do Q\n".utf8), states: [], formPDF: try nativeDrawing(page)
            )
        default:
            overlays[page] = line(page, y: 20 + page)
        }
    }
    return overlays
}

/// Which pages have been asked for and which handed back, to check the
/// window: a page is asked for only once the page `limit` before it is
/// done — its answer waiting its turn counts against the window as much as
/// a page being made does.
private final class Window: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: Set<Int> = []
    private var breaches: [Int] = []

    func started(_ position: Int, limit: Int) {
        lock.withLock {
            if position >= limit, !(0...(position - limit)).allSatisfy(finished.contains) {
                breaches.append(position)
            }
        }
    }

    func finished(_ position: Int) {
        _ = lock.withLock { finished.insert(position) }
    }

    var breached: [Int] { lock.withLock { breaches } }
}

/// `object` with every reference replaced by what it names, all the way
/// down: two updates that number the same objects differently resolve alike.
private func resolvedDeep(_ object: PDFObject?, in file: PDFFile, depth: Int = 0) throws -> PDFObject {
    guard depth < 64 else { throw PDFReadError.malformed("too deep") }
    switch try file.resolve(object) {
    case .array(let items):
        return .array(try items.map { try resolvedDeep($0, in: file, depth: depth + 1) })
    case .dictionary(let entries):
        return .dictionary(try entries.mapValues { try resolvedDeep($0, in: file, depth: depth + 1) })
    case .stream(let dictionary, let data):
        return .stream(dictionary: try dictionary.mapValues { try resolvedDeep($0, in: file, depth: depth + 1) }, data: data)
    case let resolved:
        return resolved
    }
}

@Test(
    "Pages made side by side are written in order: the file is the one a page at a time makes",
    arguments: [false, true]
)
func concurrentWriteMatchesSequential(nativeDrawings: Bool) async throws {
    let pageCount = 30
    let original = try blankDocument(pages: pageCount)
    let sequential = original.deletingPathExtension().appendingPathExtension("sequential.pdf")
    let concurrent = original.deletingPathExtension().appendingPathExtension("concurrent.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    // Every page but every fifth: the update's numbers run past pages that
    // are not in it.
    let indices = (0..<pageCount).filter { !$0.isMultiple(of: 5) && (nativeDrawings || $0 % 4 != 2) }
    let overlays = try mixedOverlays(pages: indices)
    let file = try PDFFile(url: original)

    try PDFOverlayWriter().write(
        file: file, pages: try file.pages(), original: original, pageIndices: indices, to: sequential
    ) { page in try #require(overlays[page]) }

    let limit = 3
    let window = Window()
    let positions = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($1, $0) })
    try await PDFOverlayWriter().writeConcurrently(
        file: file, pages: try file.pages(), original: original, pageIndices: indices, to: concurrent, limit: limit
    ) { page in
        let position = try #require(positions[page])
        window.started(position, limit: limit)
        // The first of every few pages the slowest, so that the pages after
        // it finish first and wait.
        try await Task.sleep(for: .milliseconds(position.isMultiple(of: 4) ? 8 : 1))
        window.finished(position)
        return try #require(overlays[page])
    }

    let written = try Data(contentsOf: concurrent)
    let expected = try Data(contentsOf: sequential)
    // A native drawing's objects are numbered in the order its dictionaries
    // are walked, and a dictionary's order is its hash seed's: two runs in
    // one process may number them differently, as two runs of the writer
    // always could. Under deterministic hashing they may not; otherwise the
    // two files must say the same thing however they number it.
    if !nativeDrawings || ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] != nil {
        #expect(written == expected)
    } else {
        #expect(written.count == expected.count)
        let one = try PDFFile(bytes: written), other = try PDFFile(bytes: expected)
        for page in indices {
            let mine = try resolvedDeep(try form("RMOverlay", of: one, page: page).dictionary["Resources"], in: one)
            let theirs = try resolvedDeep(try form("RMOverlay", of: other, page: page).dictionary["Resources"], in: other)
            #expect(mine == theirs, "page \(page)")
            #expect(try form("RMOverlay", of: one, page: page).data == (try form("RMOverlay", of: other, page: page).data))
        }
    }
    #expect(window.breached.isEmpty, "pages asked for past the window: \(window.breached)")
    #expect(try PDFFile(url: concurrent).pages().count == pageCount)
    #expect(PDFDocument(url: concurrent)?.pageCount == pageCount)
    for page in indices.prefix(4) {
        #expect(try darkPixels(concurrent, page: page + 1) > (try darkPixels(original, page: page + 1)), "page \(page)")
    }
    #expect(try leftovers(beside: concurrent).isEmpty)
}

@Test("A page that fails half way, being made or being prepared, leaves the destination as it was")
func concurrentWriteCleansUpAfterAFailure() async throws {
    struct Stop: Error {}
    let original = try blankDocument(pages: 12)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let earlier = Data("what was here before".utf8)
    try earlier.write(to: output)
    let file = try PDFFile(url: original)

    // Made: the caller's closure throws.
    await #expect(throws: Stop.self) {
        try await PDFOverlayWriter().writeConcurrently(
            file: file, pages: try file.pages(), original: original, pageIndices: Array(0..<12), to: output, limit: 3
        ) { page in
            guard page != 6 else { throw Stop() }
            return line(page)
        }
    }
    #expect(try Data(contentsOf: output) == earlier)
    #expect(try leftovers(beside: output).isEmpty)

    // Prepared: the native drawing handed over is no PDF.
    await #expect(throws: PDFReadError.self) {
        try await PDFOverlayWriter().writeConcurrently(
            file: file, pages: try file.pages(), original: original, pageIndices: Array(0..<12), to: output, limit: 3
        ) { page in
            guard page == 6 else { return line(page) }
            return PDFOverlayWriter.Overlay(
                pageIndex: page, content: Data("q /RMNative Do Q\n".utf8), states: [], formPDF: Data("not a PDF".utf8)
            )
        }
    }
    #expect(try Data(contentsOf: output) == earlier)
    #expect(try leftovers(beside: output).isEmpty)
}

@Test("A write cancelled half way stops and leaves no file behind")
func concurrentWriteStopsWhenCancelled() async throws {
    let original = try blankDocument(pages: 12)
    let output = original.deletingPathExtension().appendingPathExtension("out.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let file = try PDFFile(url: original)
    let pages = try file.pages()
    let gate = Gate()
    let work = Task {
        try await PDFOverlayWriter().writeConcurrently(
            file: file, pages: pages, original: original, pageIndices: Array(0..<12), to: output, limit: 3
        ) { page in
            if page == 4 { await gate.stopHere() }
            // What the renderer asks once a page.
            try Task.checkCancellation()
            return line(page)
        }
    }
    await gate.waitForArrival()
    work.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try leftovers(beside: output).isEmpty)
}

@Test("A cross-reference row is padded as the formatter pads it")
func crossReferencePadding() {
    let values = [0, 1, 9, 10, 99_999, 100_000, 123_456_789, 9_999_999_999, 10_000_000_000, Int.max, -1, -42, Int.min]
    for value in values {
        for width in [5, 10] {
            var padded: [UInt8] = []
            PDFOverlayWriter.appendPadded(value, width: width, to: &padded)
            #expect(String(decoding: padded, as: UTF8.self) == String(format: "%0*ld", width, value), "\(value)")
        }
    }
}
