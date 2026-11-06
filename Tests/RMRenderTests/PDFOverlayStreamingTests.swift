// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
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
