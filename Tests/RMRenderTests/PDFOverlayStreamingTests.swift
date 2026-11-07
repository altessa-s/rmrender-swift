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
    try nativeDrawing(text: "page \(seed)", picture: seed)
}

/// The same with the text and the picture chosen apart: two drawings that
/// share one of them share its objects in the overlay.
private func nativeDrawing(text line: String, picture seed: Int, at origin: CGPoint = CGPoint(x: 20, y: 250)) throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let text = NSAttributedString(
        string: line,
        attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
    )
    context.textPosition = origin
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
            // The text of its own page, a picture one of three: some of
            // the drawings' objects are shared, some are not.
            overlays[page] = PDFOverlayWriter.Overlay(
                pageIndex: page, content: Data("q /RMNative Do Q\n".utf8), states: [],
                formPDF: try nativeDrawing(text: "page \(page)", picture: page % 3)
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

    #expect(try Data(contentsOf: concurrent) == (try Data(contentsOf: sequential)))
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

// MARK: - What the native drawings share

/// Every pixel of one page (counted from one), drawn by CoreGraphics at
/// twice its size.
private func pixels(_ url: URL, page: Int) throws -> Data {
    let provider = try #require(CGDataProvider(url: url as CFURL))
    let document = try #require(CGPDFDocument(provider))
    let pdfPage = try #require(document.page(at: page))
    let box = pdfPage.getBoxRect(.mediaBox)
    let width = Int(box.width) * 2, height = Int(box.height) * 2
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(pdfPage)
    return Data(bytes: try #require(context.data), count: width * height * 4)
}

/// The references among the resources of the native drawing of `page`, by
/// kind and name: which objects that page's drawing uses.
private func nativeResources(of file: PDFFile, page: Int) throws -> [String: PDFObject] {
    let native = try form("RMNative", of: file, page: page, inside: "RMOverlay")
    let resources = try #require(try file.resolve(native.dictionary["Resources"]).dictionaryValue)
    var references: [String: PDFObject] = [:]
    for kind in ["Font", "XObject", "ColorSpace"] {
        for (name, value) in try file.resolve(resources[kind]).dictionaryValue ?? [:] {
            references["\(kind)/\(name)"] = value
        }
    }
    return references
}

@Test("A picture and a typeface drawn on many pages are written once, and every page draws as it did")
func nativeObjectsAreShared() async throws {
    let original = try blankDocument(pages: 6)
    let output = original.deletingPathExtension().appendingPathExtension("shared.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    // Four pages with the same words and picture in different places, a
    // fifth with words and a picture of its own, a sixth with a line.
    var overlays: [PDFOverlayWriter.Overlay] = []
    for page in 0..<4 {
        overlays.append(PDFOverlayWriter.Overlay(
            pageIndex: page, content: Data("q /RMNative Do Q\n".utf8), states: [],
            formPDF: try nativeDrawing(text: "the same words", picture: 1, at: CGPoint(x: 20, y: 200 + 10 * page))
        ))
    }
    overlays.append(PDFOverlayWriter.Overlay(
        pageIndex: 4, content: Data("q /RMNative Do Q\n".utf8), states: [],
        formPDF: try nativeDrawing(text: "quite other text", picture: 2)
    ))
    overlays.append(line(5))
    try PDFOverlayWriter().write(original: original, overlays: overlays, to: output)

    let file = try PDFFile(url: output)
    #expect(try file.pages().count == 6)
    #expect(PDFDocument(url: output)?.pageCount == 6)
    let first = try nativeResources(of: file, page: 0)
    #expect(first.keys.contains { $0.hasPrefix("Font/") })
    #expect(first.keys.contains { $0.hasPrefix("XObject/") })
    for page in 1..<4 {
        #expect(try nativeResources(of: file, page: page) == first, "page \(page)")
    }
    let other = try nativeResources(of: file, page: 4)
    let pictures = { (resources: [String: PDFObject]) in resources.filter { $0.key.hasPrefix("XObject/") }.values }
    #expect(Set(pictures(other).map { "\($0)" }).isDisjoint(with: pictures(first).map { "\($0)" }))

    // In the update itself, one picture and one typeface for the four pages
    // and one each for the fifth: nothing written twice.
    let update = try Data(contentsOf: output).dropFirst(try Data(contentsOf: original).count)
    let count = { (needle: String) in
        var found = 0
        var start = update.startIndex
        while let range = update.range(of: Data(needle.utf8), in: start..<update.endIndex) {
            found += 1
            start = range.upperBound
        }
        return found
    }
    #expect(count("/Subtype /Image") == 2)
    #expect(count("/Type /FontDescriptor") == 2)

    // Each page drawn as it is when it is the only one in its update, and
    // so has nothing to share: to the pixel.
    for overlay in overlays {
        let alone = original.deletingPathExtension().appendingPathExtension("alone\(overlay.pageIndex).pdf")
        try PDFOverlayWriter().write(original: original, overlays: [overlay], to: alone)
        let page = overlay.pageIndex + 1
        #expect(try pixels(output, page: page) == (try pixels(alone, page: page)), "page \(page)")
        #expect(try pixels(output, page: page) != (try pixels(original, page: page)), "page \(page)")
    }
}

@Test("A fingerprint is what an object says, whatever its number, and none for a cycle")
func nativeFingerprints() throws {
    let program = PDFObject.stream(dictionary: ["Length": .integer(3)], data: Data("abc".utf8))
    func descriptor(_ file: Int) -> PDFObject {
        .dictionary(["Type": .name("FontDescriptor"), "FontFile2": .reference(number: file, generation: 0)])
    }
    // The program numbered first, then numbered second.
    let early = try #require(PDFOverlayWriter.fingerprint(program, known: [nil, nil]))
    let late = try #require(PDFOverlayWriter.fingerprint(program, known: [nil, nil]))
    #expect(early == late)
    let one = PDFOverlayWriter.fingerprint(descriptor(0), known: [early, nil])
    let two = PDFOverlayWriter.fingerprint(descriptor(1), known: [nil, late])
    #expect(one != nil)
    #expect(one == two)
    // Another program: another descriptor.
    let otherProgram = PDFObject.stream(dictionary: ["Length": .integer(3)], data: Data("abd".utf8))
    let other = try #require(PDFOverlayWriter.fingerprint(otherProgram, known: [nil, nil]))
    #expect(PDFOverlayWriter.fingerprint(descriptor(0), known: [other, nil]) != one)
    // Neither the dictionary nor the stream's bytes taken for the other.
    #expect(PDFOverlayWriter.fingerprint(.dictionary(["Length": .integer(3)]), known: []) != early)
    // A reference to what has no fingerprint yet — a cycle — gives none.
    #expect(PDFOverlayWriter.fingerprint(descriptor(1), known: [nil, nil]) == nil)
    #expect(PDFOverlayWriter.fingerprint(descriptor(7), known: [nil, nil]) == nil)
    // A layer is the object itself, and is never taken for another.
    let layer = PDFObject.dictionary(["Type": .name("OCG"), "Name": .string(Data("(Ink)".utf8))])
    #expect(PDFOverlayWriter.fingerprint(layer, known: []) == nil)
    let marked = PDFObject.dictionary(["OC": .dictionary(["Type": .name("OCMD"), "P": .name("AnyOn")])])
    #expect(PDFOverlayWriter.fingerprint(marked, known: []) == nil)
}

/// A one-page PDF written by hand whose resources refer back to themselves:
/// a Form naming itself among its own XObjects, which CoreGraphics never
/// writes and a file may.
private func cyclicDrawing() -> Data {
    let content = "q /X1 Do Q"
    let drawing = "0 g 60 200 80 40 re f"
    let bodies = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << /XObject << /X1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        """
        << /Type /XObject /Subtype /Form /BBox [0 0 200 300] /Resources << /XObject << /Me 5 0 R >> >> \
        /Length \(drawing.utf8.count) >>\nstream\n\(drawing)\nendstream
        """,
    ]
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, body) in bodies.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
    }
    let table = pdf.utf8.count
    pdf += "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
    return Data(pdf.utf8)
}

@Test("An object that refers back to itself is written on every page that has it, and draws")
func cyclicNativeObjectsAreNotShared() throws {
    let original = try blankDocument(pages: 3)
    let output = original.deletingPathExtension().appendingPathExtension("cyclic.pdf")
    defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
    let overlays = (0..<2).map {
        PDFOverlayWriter.Overlay(pageIndex: $0, content: Data("q /RMNative Do Q\n".utf8), states: [], formPDF: cyclicDrawing())
    } + [line(2)]
    try PDFOverlayWriter().write(original: original, overlays: overlays, to: output)

    let file = try PDFFile(url: output)
    #expect(try file.pages().count == 3)
    #expect(PDFDocument(url: output)?.pageCount == 3)
    var forms: [PDFObject] = []
    for page in 0..<2 {
        let reference = try #require(try nativeResources(of: file, page: page)["XObject/X1"])
        forms.append(reference)
        // Still itself: the Form names its own number.
        guard case .stream(let dictionary, _) = try file.resolve(reference) else {
            Issue.record("no Form on page \(page)")
            continue
        }
        let own = try file.resolve(dictionary["Resources"]).dictionaryValue?["XObject"]
        #expect(try file.resolve(own).dictionaryValue?["Me"] == reference)
        #expect(try darkPixels(output, page: page + 1) > (try darkPixels(original, page: page + 1)) + 2000)
    }
    #expect(forms[0] != forms[1])
}

// MARK: - The same file from every process

/// Where `writeOverlayForAnotherProcess` writes, and from what: set only in a
/// process `overlayIsTheSameInEveryProcess` starts.
private let overlayOriginalKey = "RMRENDER_TEST_OVERLAY_ORIGINAL"
private let overlayOutputKey = "RMRENDER_TEST_OVERLAY_OUTPUT"

/// The pages the processes write: every kind of overlay, native drawings
/// among them, and pages left out.
private let crossProcessPages = (0..<16).filter { !$0.isMultiple(of: 5) }

private func writeCrossProcessOverlay(original: URL, to output: URL) async throws {
    let overlays = try mixedOverlays(pages: crossProcessPages)
    let file = try PDFFile(url: original)
    try await PDFOverlayWriter().writeConcurrently(
        file: file, pages: try file.pages(), original: original, pageIndices: crossProcessPages, to: output, limit: 3
    ) { page in try #require(overlays[page]) }
}

/// Whether this process was started by `swift test`, whose runner can be
/// started again with a filter of its own.
private let runnerCanBeRestarted = CommandLine.arguments.first?.hasSuffix("swiftpm-testing-helper") == true
    && CommandLine.arguments.contains("--test-bundle-path")

@Test(
    "The other half of the test below: writes the overlay where the process that started it says",
    .enabled(if: ProcessInfo.processInfo.environment[overlayOutputKey] != nil)
)
func writeOverlayForAnotherProcess() async throws {
    let environment = ProcessInfo.processInfo.environment
    let original = URL(fileURLWithPath: try #require(environment[overlayOriginalKey]))
    let output = URL(fileURLWithPath: try #require(environment[overlayOutputKey]))
    try await writeCrossProcessOverlay(original: original, to: output)
}

@Test(
    "The same overlay is the same bytes whichever process writes it, and whatever its hash seed",
    .enabled(if: runnerCanBeRestarted)
)
func overlayIsTheSameInEveryProcess() async throws {
    let original = try blankDocument(pages: 16)
    let folder = original.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    let here = folder.appending(path: "here.pdf")
    try await writeCrossProcessOverlay(original: original, to: here)

    // The runner started again, asked for the test above alone: twice with
    // a hash seed of its own each time, once with the fixed one.
    var arguments = Array(CommandLine.arguments.dropFirst())
    if let filter = arguments.firstIndex(of: "--filter"), filter + 1 < arguments.count {
        arguments.removeSubrange(filter...(filter + 1))
    }
    arguments += ["--filter", "writeOverlayForAnotherProcess"]
    // A run under a sanitizer carries its runtime beside the test bundle, and
    // a process started from here has to be handed it again, or it stops
    // before it starts.
    var sanitizers: [String] = []
    if let bundle = arguments.firstIndex(of: "--test-bundle-path").map({ arguments[$0 + 1] }) {
        let frameworks = URL(fileURLWithPath: bundle).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        sanitizers = names.filter { $0.hasPrefix("libclang_rt.") && $0.hasSuffix("_osx_dynamic.dylib") }
            .sorted().map { frameworks.appending(path: $0).path }
    }
    var written: [Data] = []
    for (run, deterministic) in [false, false, true].enumerated() {
        let output = folder.appending(path: "process\(run).pdf")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        if deterministic { environment["SWIFT_DETERMINISTIC_HASHING"] = "1" }
        environment[overlayOriginalKey] = original.path
        environment[overlayOutputKey] = output.path
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
        written.append(try Data(contentsOf: output))
    }

    let expected = try Data(contentsOf: here)
    for (run, bytes) in written.enumerated() {
        #expect(bytes == expected, "run \(run)")
    }
    #expect(try PDFFile(bytes: expected).pages().count == 16)
    #expect(PDFDocument(data: expected)?.pageCount == 16)
}
