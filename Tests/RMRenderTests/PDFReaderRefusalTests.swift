// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import Testing

// The reader opens whatever original a host hands it, and every one of these
// files can end the process if unguarded: a trap is not an error, and no
// `catch` upstream sees one. What dies with the process is every other read
// and write in flight, any half-written output, and the completion a caller
// is waiting on. So the bar here is lower than "reads it correctly": a
// broken file has to come back as a `PDFReadError`, which the renderer
// answers by redrawing the document whole.

/// A PDF assembled byte by byte, so that a test can put in it the things no
/// writer produces: an offset that points before the file, a `/Prev` that
/// points nowhere, a media box of numbers that are not numbers.
private func handwrittenPDF(
    mediaBox: String = "[0 0 200 200]",
    trailerExtras: String = "",
    xrefRows: [Int: String] = [:],
    subsectionHeading: String? = nil,
    size: String? = nil
) -> Data {
    var body = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = [0]
    func emit(_ number: Int, _ text: String) {
        offsets.append(body.count)
        body.append(contentsOf: Array("\(number) 0 obj\n\(text)\nendobj\n".utf8))
    }
    emit(1, "<< /Type /Catalog /Pages 2 0 R >>")
    emit(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    emit(3, "<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) >>")

    let startxref = body.count
    var table = "xref\n\(subsectionHeading ?? "0 \(offsets.count)")\n0000000000 65535 f \n"
    for (number, offset) in offsets.enumerated().dropFirst() {
        table += (xrefRows[number] ?? String(format: "%010d", offset)) + " 00000 n \n"
    }
    body.append(contentsOf: Array(table.utf8))
    body.append(contentsOf: Array("""
    trailer
    << /Size \(size ?? String(offsets.count)) /Root 1 0 R \(trailerExtras) >>
    startxref
    \(startxref)
    %%EOF

    """.utf8))
    return body
}

@Test("A cross-reference row that points before the file is not followed there")
func readerRefusesANegativeObjectOffset() throws {
    // Unguarded, `bytes[startIndex - 1]` would be the read, and the row that
    // asks for it is one character of difference from a row a writer
    // produces.
    let file = try PDFFile(bytes: handwrittenPDF(xrefRows: [1: "-000000001"]))
    #expect(throws: PDFReadError.self) { try file.pages() }
}

@Test("A scanner started outside its bytes reads nothing rather than reading anyway")
func scannerDefendsBothEndsOfItsBytes() throws {
    var before = PDFScanner(bytes: Data("1 0 obj".utf8), index: -5)
    #expect(try before.nextObject() == nil)

    var after = PDFScanner(bytes: Data("1 0 obj".utf8), index: 99)
    #expect(try after.nextObject() == nil)

    // The keyword is looked for by counting to the end rather than by adding
    // to the index: the addition overflows on an index a broken offset made.
    var far = PDFScanner(bytes: Data("xref".utf8), index: Int.max)
    #expect(far.readKeyword("xref") == false)
}

@Test("A stream whose /Length is negative is refused, not read backwards")
func scannerRefusesANegativeStreamLength() throws {
    var scanner = PDFScanner(bytes: Data("<</Length -5>>\nstream\nabcdefgh".utf8), index: 0)
    #expect(throws: PDFReadError.self) { try scanner.nextObject() }
}

@Test("A stream whose /Length is the largest number there is is refused too")
func scannerRefusesAStreamLengthThatOverflows() throws {
    // The addition that compares the end of the stream with the end of the
    // file is itself the trap: it overflows before anything is compared.
    var scanner = PDFScanner(
        bytes: Data("<</Length 9223372036854775807>>\nstream\nabcdefgh".utf8),
        index: 0
    )
    #expect(throws: PDFReadError.self) { try scanner.nextObject() }
}

@Test("A number no integer can hold is no integer, rather than a dead process")
func realsThatAreNotWholeNumbersAreRefused() throws {
    #expect(PDFObject.real(.nan).intValue == nil)
    #expect(PDFObject.real(.infinity).intValue == nil)
    #expect(PDFObject.real(-.infinity).intValue == nil)
    #expect(PDFObject.real(1e30).intValue == nil)
    // What still works: a real that names a whole number, and one that does
    // not, truncated the way the format truncates.
    #expect(PDFObject.real(90).intValue == 90)
    #expect(PDFObject.real(-2.75).intValue == -2)

    // The scanner makes all three from a file that says so.
    var notANumber = PDFScanner(bytes: Data("nan".utf8), index: 0)
    #expect(try notANumber.nextObject()?.intValue == nil)
    var twentyDigits = PDFScanner(bytes: Data("99999999999999999999".utf8), index: 0)
    #expect(try twentyDigits.nextObject()?.intValue == nil)
}

@Test("A /Prev is checked the way startxref is, and both ways of missing count")
func readerRefusesAPrevThatPointsNowhere() throws {
    #expect(throws: PDFReadError.self) {
        try PDFFile(bytes: handwrittenPDF(trailerExtras: "/Prev -1"))
    }
    #expect(throws: PDFReadError.self) {
        try PDFFile(bytes: handwrittenPDF(trailerExtras: "/Prev 9223372036854775807"))
    }
}

@Test("Arrays nested past what the reader will hold are refused, not recursed")
func scannerRefusesArraysNestedTooDeep() throws {
    var deep = PDFScanner(bytes: Data(String(repeating: "[", count: 5_000).utf8), index: 0)
    #expect(throws: PDFReadError.self) { try deep.nextObject() }

    // And the limit is loose: nesting a document might really carry passes.
    let nested = String(repeating: "[", count: 30) + "1" + String(repeating: "]", count: 30)
    var shallow = PDFScanner(bytes: Data(nested.utf8), index: 0)
    #expect(try shallow.nextObject() != nil)
}

@Test("Dictionaries nested past the same depth are refused on the same counter")
func scannerRefusesDictionariesNestedTooDeep() throws {
    let deep = String(repeating: "<< /A ", count: 5_000) + "1"
        + String(repeating: " >>", count: 5_000)
    var scanner = PDFScanner(bytes: Data(deep.utf8), index: 0)
    #expect(throws: PDFReadError.self) { try scanner.nextObject() }
}

@Test("A long run of plain numbers costs no stack, however long the run")
func scannerReadsARunOfNumbersWithoutRecursing() throws {
    // A font's `/Widths`. Every number looks at the one after it to see
    // whether the two of them and an `R` make a reference, and looking would
    // mean parsing — one frame per number, in an array one level deep. A
    // chain of real references never goes past three, which is why the
    // documents that work never show this.
    let widths = "[" + (0..<3_000).map(String.init).joined(separator: " ") + "]"
    var scanner = PDFScanner(bytes: Data(widths.utf8), index: 0)
    let array = try #require(try scanner.nextObject()?.arrayValue)
    #expect(array.count == 3_000)
    #expect(array.first == .integer(0))
    #expect(array.last == .integer(2_999))
}

@Test("A cross-reference subsection that starts near the end of counting is refused")
func readerRefusesASubsectionHeadingThatOverflows() throws {
    // `first + row` is the sum, and the heading names `first`.
    #expect(throws: PDFReadError.self) {
        try PDFFile(bytes: handwrittenPDF(subsectionHeading: "9223372036854775806 3"))
    }
    #expect(throws: PDFReadError.self) {
        try PDFFile(bytes: handwrittenPDF(subsectionHeading: "-4 3"))
    }
}

@Test("A media box of numbers that are not finite is refused rather than drawn")
func readerRefusesANonFiniteMediaBox() throws {
    // This one does not trap: unguarded, it comes out the other end as a
    // `CGRect` of a NaN and an infinity, and what a caller does with that is
    // draw a page nobody can explain.
    let file = try PDFFile(bytes: handwrittenPDF(mediaBox: "[0 0 nan 1e400]"))
    #expect(throws: PDFReadError.self) { try file.pages() }
}

@Test("A document handed over as a slice is read from its own first byte")
func readerReadsADocumentThatIsASliceOfSomethingLarger() throws {
    // Offsets in a PDF count from the start of the file, and the start of the
    // file is `startIndex` — which is zero only for the bytes `Data(contentsOf:)`
    // hands back. The initialiser takes anyone's `Data`.
    let padded = Data([0x0A, 0x0A, 0x0A]) + handwrittenPDF()
    let file = try PDFFile(bytes: padded[3...])
    let page = try #require(try file.pages().first)
    #expect(page.mediaBox == CGRect(x: 0, y: 0, width: 200, height: 200))
}

@Test("A trailer /Size past any object number is refused, not counted on from")
func overlayRefusesATrailerSizeThatOverflows() throws {
    // Every object the overlay adds is numbered one past the last, starting
    // from `/Size`: `Int.max` there would trap on the first object written.
    let original = FileManager.default.temporaryDirectory.appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    let output = FileManager.default.temporaryDirectory.appending(path: "rmrender-test-\(UUID().uuidString).pdf")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }
    try handwrittenPDF(size: "9223372036854775807").write(to: original)
    let overlay = PDFOverlayWriter.Overlay(pageIndex: 0, content: Data("0 0 0 RG 20 20 m 180 180 l S\n".utf8), states: [])
    #expect(throws: PDFReadError.self) {
        try PDFOverlayWriter().write(original: original, overlays: [overlay], to: output)
    }
}

@Test("A page tree chained deeper than any real one is refused, not recursed to the end of the stack")
func readerRefusesAPageTreeNestedTooDeep() throws {
    // Each `/Pages` node holds the next as its one kid: no loop for the
    // visited set to catch, only depth — and the walk is a recursion.
    let depth = 20_000
    var body = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = [0]
    func emit(_ number: Int, _ text: String) {
        offsets.append(body.count)
        body.append(contentsOf: Array("\(number) 0 obj\n\(text)\nendobj\n".utf8))
    }
    emit(1, "<< /Type /Catalog /Pages 2 0 R >>")
    for node in 2..<(depth + 2) {
        emit(node, "<< /Type /Pages /Kids [\(node + 1) 0 R] /Count 1 >>")
    }
    emit(depth + 2, "<< /Type /Page /MediaBox [0 0 200 200] >>")
    let startxref = body.count
    var table = "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() {
        table += String(format: "%010d", offset) + " 00000 n \n"
    }
    body.append(contentsOf: Array(table.utf8))
    body.append(contentsOf: Array("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n".utf8))

    let file = try PDFFile(bytes: body)
    #expect(throws: PDFReadError.self) { try file.pages() }
}

@Test("A page tree of ordinary depth is still read")
func readerReadsAModestlyNestedPageTree() throws {
    #expect(try PDFFile(bytes: handwrittenPDF()).pages().count == 1)
}
