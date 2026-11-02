// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import CoreGraphics
import Foundation
import PDFKit
@testable import RMRender
import Testing
import zlib

// Files built to make the reader do more than a file of their size should
// cost, or to make it read a different document than other readers do. Each
// one has to end in a clean `PDFReadError` or in the answer CoreGraphics
// gives — never in a trap, and never in minutes of work.

// MARK: - Fixtures

/// A PDF assembled object by object, with the offsets kept for the table.
private struct Assembly {
    var data = Data("%PDF-1.7\n".utf8)
    var offsets: [Int: Int] = [:]

    mutating func add(_ number: Int, _ body: Data) {
        offsets[number] = data.count
        data.append(Data("\(number) 0 obj\n".utf8))
        data.append(body)
        data.append(Data("\nendobj\n".utf8))
    }

    mutating func add(_ number: Int, _ body: String) { add(number, Data(body.utf8)) }

    static func stream(_ dictionary: String, _ payload: Data) -> Data {
        var out = Data("<< \(dictionary) /Length \(payload.count) >>\nstream\n".utf8)
        out.append(payload)
        out.append(Data("\nendstream".utf8))
        return out
    }

    /// A classic table over `0..<size`, numbers without an object free.
    mutating func finish(size: Int, trailer extra: String = "") {
        let start = data.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1..<size {
            table += offsets[number].map { String(format: "%010ld 00000 n \n", $0) } ?? "0000000000 00001 f \n"
        }
        table += "trailer\n<< /Size \(size) /Root 1 0 R \(extra) >>\nstartxref\n\(start)\n%%EOF\n"
        data.append(Data(table.utf8))
    }
}

private func bigEndian(_ value: Int, _ width: Int) -> [UInt8] {
    (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * (width - 1 - $0))) }
}

/// `pages` pages packed into one object stream (object 3), found through a
/// cross-reference stream (object 4). Page *i* is object `10 + i`.
private func packedPages(_ pages: Int, filtered: Bool, padding: Int = 0) -> Data {
    var file = Assembly()
    file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    let kids = (0..<pages).map { "\(10 + $0) 0 R" }.joined(separator: " ")
    file.add(2, "<< /Type /Pages /Count \(pages) /Kids [\(kids)] >>")
    var header = ""
    var bodies = Data()
    for page in 0..<pages {
        header += "\(10 + page) \(bodies.count) "
        bodies.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >> ".utf8))
    }
    var payload = Data(header.utf8)
    let first = payload.count
    payload.append(bodies)
    payload.append(Data(repeating: 0x20, count: padding))
    let stored = filtered ? PDFWriter.flate(payload) : payload
    let filter = filtered ? " /Filter /FlateDecode" : ""
    file.add(3, Assembly.stream("/Type /ObjStm /N \(pages) /First \(first)\(filter)", stored))
    let size = 10 + pages
    let table = file.data.count
    var rows: [UInt8] = []
    for number in 0..<size {
        if number == 4 {
            rows += [1] + bigEndian(table, 4) + bigEndian(0, 2)
        } else if let offset = file.offsets[number] {
            rows += [1] + bigEndian(offset, 4) + bigEndian(0, 2)
        } else if number >= 10 {
            rows += [2] + bigEndian(3, 4) + bigEndian(number - 10, 2)
        } else {
            rows += [0] + bigEndian(0, 4) + bigEndian(0, 2)
        }
    }
    file.add(4, Assembly.stream("/Type /XRef /Size \(size) /Root 1 0 R /W [1 4 2]", Data(rows)))
    file.data.append(Data("startxref\n\(table)\n%%EOF\n".utf8))
    return file.data
}

private func coreGraphics(_ bytes: Data) throws -> CGPDFDocument {
    let provider = try #require(CGDataProvider(data: bytes as CFData))
    return try #require(CGPDFDocument(provider))
}

// MARK: - Stream lengths

@Test("A /Length chain through nested arrays ends in an error, not off the end of the stack")
func nestedLengthChainIsRefused() async throws {
    var file = Assembly()
    file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    file.add(2, "<< /Type /Pages /Count 1 /Kids [3 0 R] >>")
    for number in 3..<73 {
        file.add(
            number,
            String(repeating: "[", count: 62) + "<< /Length \(number + 1) 0 R >> stream\nX\nendstream"
                + String(repeating: "]", count: 62)
        )
    }
    file.add(73, "1")
    file.finish(size: 74)
    let bytes = file.data
    // On a task of its own: the cooperative pool's stack is the small one
    // the chain used to run out.
    let refused = await Task.detached { () -> Bool in
        do {
            _ = try PDFFile(bytes: bytes).pages()
            return false
        } catch {
            return error is PDFReadError
        }
    }.value
    #expect(refused)
}

// MARK: - Object streams

@Test("An object stream is decoded once however many objects it holds")
func objectStreamDecodedOnce() throws {
    let file = try PDFFile(bytes: packedPages(4_000, filtered: true))
    let before = file.decodeCount
    let started = Date()
    let pages = try file.pages()
    #expect(pages.count == 4_000)
    #expect(pages[3_999].mediaBox == CGRect(x: 0, y: 0, width: 10, height: 10))
    #expect(file.decodeCount - before == 1)
    // Generous: quadratic decoding took a minute here in a debug build.
    #expect(Date().timeIntervalSince(started) < 20)
}

@Test("An unfiltered object stream reads the same pages CoreGraphics does")
func unfilteredObjectStream() throws {
    let bytes = packedPages(2, filtered: false)
    let pages = try PDFFile(bytes: bytes).pages()
    #expect(pages.count == 2)
    #expect(pages.count == (try coreGraphics(bytes)).numberOfPages)
    #expect(pages[1].number == 11)
}

@Test("An object stream padded far past its objects is read, and costs one decode")
func paddedObjectStream() throws {
    let file = try PDFFile(bytes: packedPages(200, filtered: true, padding: 8 * 1024 * 1024))
    let before = file.decodeCount
    #expect(try file.pages().count == 200)
    #expect(file.decodeCount - before == 1)
}

@Test("A file's decoding is held to its budget, failures included")
func decodeBudget() throws {
    let state = PDFDecodeState(budget: 1_000)
    let flate: [String: PDFObject] = ["Filter": .name("FlateDecode")]
    #expect(try state.decode(flate, PDFWriter.flate(Data(repeating: 7, count: 600))).count == 600)
    #expect(throws: PDFReadError.self) { try state.decode(flate, PDFWriter.flate(Data(repeating: 7, count: 600))) }
    #expect(throws: PDFReadError.self) { try state.decode(flate, PDFWriter.flate(Data([1]))) }

    let failing = PDFDecodeState(budget: 1_000)
    #expect(throws: PDFReadError.self) { try failing.decode(flate, Data([0x78, 0x9C, 0xFF])) }
    #expect(throws: PDFReadError.self) { try failing.decode(flate, PDFWriter.flate(Data([1]))) }
}

@Test("A stream decoding past the per-stream limit is refused")
func oversizedStream() throws {
    let zeros = [UInt8](repeating: 0, count: PDFStreamCodec.limit + 1)
    var length = compressBound(uLong(zeros.count))
    var compressed = [UInt8](repeating: 0, count: Int(length))
    #expect(compress(&compressed, &length, zeros, uLong(zeros.count)) == Z_OK)
    let bomb = Data(compressed.prefix(Int(length)))
    #expect(bomb.count < 1024 * 1024)
    #expect(throws: PDFReadError.self) {
        try PDFStreamCodec.decode(["Filter": .name("FlateDecode")], bomb)
    }
}

// MARK: - Cross-reference sections

@Test("A hybrid file's table wins over its stream, as it does for CoreGraphics and PDFKit")
func hybridTableWins() throws {
    var file = Assembly()
    file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    file.add(2, "<< /Type /Pages /Count 1 /Kids [3 0 R] >>")
    file.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
    let shadow = file.data.count
    file.data.append(Data("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 555 555] >>\nendobj\n".utf8))
    let stream = file.data.count
    let rows: [UInt8] = [1] + bigEndian(shadow, 4) + bigEndian(0, 2)
    file.add(5, Assembly.stream("/Type /XRef /Size 6 /Index [3 1] /W [1 4 2]", Data(rows)))
    file.finish(size: 6, trailer: "/XRefStm \(stream)")

    let ours = try PDFFile(bytes: file.data).pages().first?.mediaBox
    let theirs = try coreGraphics(file.data).page(at: 1)?.getBoxRect(.mediaBox)
    #expect(ours == CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(ours == theirs)
    #expect(ours == PDFDocument(data: file.data)?.page(at: 0)?.bounds(for: .mediaBox))
}

@Test("Sections that repeat the same rows are held to a total, quickly")
func repeatedSectionsAreBounded() throws {
    var file = Assembly()
    file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    let payload = PDFWriter.flate(Data(repeating: 1, count: 500_000))
    var previous: Int?
    for section in 0..<16 {
        let start = file.data.count
        let prev = previous.map { " /Prev \($0)" } ?? ""
        file.add(
            1_000_000 + section,
            Assembly.stream("/Type /XRef /Size 500000 /Root 1 0 R /W [0 1 0] /Filter /FlateDecode\(prev)", payload)
        )
        previous = start
    }
    file.data.append(Data("startxref\n\(previous ?? 0)\n%%EOF\n".utf8))
    let started = Date()
    #expect(throws: PDFReadError.self) { try PDFFile(bytes: file.data) }
    #expect(Date().timeIntervalSince(started) < 20)
}

@Test("A cross-reference stream's predictor must work on rows of its own width")
func crossReferencePredictorWidth() throws {
    // Two entries, free 0 and object 1, laid out as one predictor row of
    // ten bytes or as two of five. Both decode to the same table; only the
    // second is a table of rows.
    func table(columns: Int) -> Data {
        var file = Assembly()
        file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
        let start = file.data.count
        let entries: [UInt8] = [0, 0, 0, 0, 0] + [1] + bigEndian(file.offsets[1] ?? 0, 4)
        var rows: [UInt8] = []
        for row in stride(from: 0, to: entries.count, by: columns) {
            rows += [0] + entries[row..<(row + columns)]
        }
        file.add(2, Assembly.stream(
            "/Type /XRef /Size 2 /Root 1 0 R /W [1 4 0] /Filter /FlateDecode "
                + "/DecodeParms << /Predictor 12 /Columns \(columns) >>",
            PDFWriter.flate(Data(rows))
        ))
        file.data.append(Data("startxref\n\(start)\n%%EOF\n".utf8))
        return file.data
    }
    #expect(try PDFFile(bytes: table(columns: 5)).offsets[1] != nil)
    #expect(throws: PDFReadError.self) { try PDFFile(bytes: table(columns: 10)) }
}

@Test("A predictor over nothing, or over rows wider than any table, is refused")
func predictorBounds() throws {
    let empty = PDFWriter.flate(Data())
    #expect(throws: PDFReadError.self) {
        try PDFStreamCodec.decode([
            "Filter": .name("FlateDecode"),
            "DecodeParms": .dictionary(["Predictor": .integer(12), "Columns": .integer(4)]),
        ], empty)
    }
    #expect(throws: PDFReadError.self) {
        try PDFStreamCodec.decode([
            "Filter": .name("FlateDecode"),
            "DecodeParms": .dictionary(["Predictor": .integer(2), "Columns": .integer(1 << 20)]),
        ], PDFWriter.flate(Data([1, 2, 3])))
    }
}

// MARK: - Names

@Test("A name's bytes come back as they went in, UTF-8 or not")
func nameBytesRoundTrip() throws {
    var scanner = PDFScanner(bytes: Data("<< /F#e9 1 /G#82#6c 2 /Caf#c3#a9 3 >>".utf8), index: 0)
    let object = try #require(try scanner.nextObject())
    #expect(object.dictionaryValue?.count == 3)
    let written = PDFWriter.bytes(of: object)
    #expect(written == Data("<</Caf#c3#a9 3 /F#e9 1 /G#82l 2 >>".utf8))
    #expect(PDFWriter.bytes(of: .name("RMOverlay_")) == Data("/RMOverlay_".utf8))
}

// MARK: - Writing

@Test("New objects are numbered past every number the file names, free ones included")
func freedNumbersAreNotReused() throws {
    var file = Assembly()
    file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    file.add(2, "<< /Type /Pages /Count 1 /Kids [3 0 R] >>")
    file.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
    file.finish(size: 51)
    // The trailer says 4: a file whose `/Size` stops short of its own table.
    let bytes = Data(String(decoding: file.data, as: UTF8.self).replacingOccurrences(of: "/Size 51", with: "/Size 4").utf8)
    let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let output = source.appendingPathExtension("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: output)
    }
    try bytes.write(to: source)
    #expect(try PDFFile(bytes: bytes).highestObjectNumber == 50)
    try PDFOverlayWriter().write(original: source, overlays: [
        .init(pageIndex: 0, content: Data("0 g 1 1 5 5 re f".utf8), states: []),
    ], to: output)
    let written = try PDFFile(url: output)
    #expect(!written.offsets.keys.contains { (4...50).contains($0) })
    #expect(try written.pages().count == 1)
}

@Test("Cross-reference rows carry offsets past four gigabytes whole")
func wideCrossReferenceOffsets() {
    let table = PDFOverlayWriter().crossReferenceTable([7: 5_000_000_000], generations: [7: 3])
    #expect(table == Data("xref\n7 1\n5000000000 00003 n \n".utf8))
}

@Test("An original that changed after it was read is refused, not appended to")
func changedOriginalIsRefused() throws {
    var file = Assembly()
    file.add(1, "<< /Type /Catalog /Pages 2 0 R >>")
    file.add(2, "<< /Type /Pages /Count 1 /Kids [3 0 R] >>")
    file.add(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
    file.finish(size: 4)
    let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let output = source.appendingPathExtension("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: output)
    }
    let read = try PDFFile(bytes: file.data)
    try (file.data + Data("% appended later\n".utf8)).write(to: source)
    #expect(throws: PDFReadError.self) {
        try PDFOverlayWriter().write(file: read, pages: try read.pages(), original: source, overlays: [
            .init(pageIndex: 0, content: Data("0 g 1 1 5 5 re f".utf8), states: []),
        ], to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

// MARK: - Navigation

@Test("A local link keeps its own rectangle, not the target page's")
func localLinkRectangle() throws {
    let original = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: original))
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setDestination("end" as CFString, for: CGRect(x: 10, y: 10, width: 20, height: 20))
    context.endPDFPage()
    context.beginPDFPage(nil)
    context.addDestination("end" as CFString, at: CGPoint(x: 25, y: 200))
    context.endPDFPage()
    context.closePDF()
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try (original as Data).write(to: url)
    let source = try coreGraphics(original as Data)
    let navigation = try PDFNavigation(original: url, document: source,
                                       mapping: [(0, true, box.size), (1, true, box.size)])
    let link = try #require(navigation.links[0]?.first)
    #expect(abs(link.box.minX - 10) < 0.0001)
    #expect(abs(link.box.minY - 10) < 0.0001)
    #expect(abs(link.box.width - 20) < 0.0001)
    #expect(abs(link.box.height - 20) < 0.0001)
}
