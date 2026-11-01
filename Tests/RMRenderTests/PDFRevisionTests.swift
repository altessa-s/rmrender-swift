// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import CoreGraphics
import Foundation
@testable import RMRender
import Testing

private func revisionFixture(generation: Int = 0, contents: String = "null", permissions: Bool = false, extra: String = "") -> Data {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R \(permissions ? "/Perms << /DocMDP 3 0 R >>" : "") >>",
        "<< /Type /Pages /Kids [3 \(generation) R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] \(extra) /Contents \(contents) /Resources << /ExtGState << /Shared << /ca 1 >> >> /XObject << /RMOverlay null >> >> >>",
    ]
    var data = Data("%PDF-1.4\n".utf8)
    var offsets = [Int]()
    for (index, object) in objects.enumerated() {
        offsets.append(data.count)
        data.append(Data("\(index + 1) \(index == 2 ? generation : 0) obj\n\(object)\nendobj\n".utf8))
    }
    let xref = data.count
    data.append(Data("xref\n0 4\n0000000000 65535 f \n".utf8))
    for (index, offset) in offsets.enumerated() {
        data.append(Data(String(format: "%010d %05d n \n", offset, index == 2 ? generation : 0).utf8))
    }
    data.append(Data("trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return data
}

@Test("Nonzero page generations and null contents survive two visible overlay revisions")
func revisionGenerationsAndNull() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appending(path: "original.pdf")
    try revisionFixture(generation: 7).write(to: original)
    var input = original
    for index in 0..<2 {
        let output = directory.appending(path: "revision\(index).pdf")
        try PDFOverlayWriter().write(original: input, overlays: [
            .init(pageIndex: 0, content: Data("q /Shared gs 0 g 10 10 20 20 re f Q".utf8),
                  states: [.init(name: "Shared", blendMode: nil, alpha: 1)]),
        ], to: output)
        let file = try PDFFile(url: output)
        #expect(file.generations[3] == 7)
        let page = try #require(try file.pages().first)
        let resources = try #require(try file.resolve(page.resources).dictionaryValue)
        let states = try #require(try file.resolve(resources["ExtGState"]).dictionaryValue)
        #expect(try file.resolve(states["Shared"]).dictionaryValue?["ca"] == .integer(1))
        let document = try #require(CGPDFDocument(output as CFURL))
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                            bytesPerRow: 100, space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.drawPDFPage(try #require(document.page(at: 1)))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect((0..<10000).filter { pixels[$0] < 128 }.count == 400)
        input = output
    }
}

@Test("Free entries shadow older objects and references check generations")
func revisionReferenceValidation() throws {
    let original = revisionFixture(generation: 7)
    let file = try PDFFile(bytes: original)
    #expect(throws: PDFReadError.self) { try file.resolve(.reference(number: 3, generation: 0)) }
    var freed = original
    freed.append(Data("xref\n3 1\n0000000000 00008 f \ntrailer\n<< /Size 4 /Prev \(file.lastCrossReference) >>\nstartxref\n\(original.count)\n%%EOF\n".utf8))
    #expect(throws: PDFReadError.self) { try PDFFile(bytes: freed).pages() }
    var scanner = PDFScanner(bytes: Data("<< /A 1 /A 2 >>".utf8), index: 0)
    #expect(throws: PDFReadError.self) { try scanner.nextObject() }
}

@Test("Certification permissions refuse an incremental write before touching output")
func revisionCertification() throws {
    let original = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let output = original.appendingPathExtension("out")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }
    try revisionFixture(permissions: true).write(to: original)
    let sentinel = Data("unchanged".utf8)
    try sentinel.write(to: output)
    #expect(throws: PDFOverlayWriter.OverlayError.certifiedDocument) {
        try PDFOverlayWriter().write(original: original, overlays: [], to: output)
    }
    #expect(try Data(contentsOf: output) == sentinel)
}

@Test("Only the default PDF user unit is supported", arguments: ["2", "0", "null", "(one)"])
func revisionUserUnit(_ unit: String) throws {
    #expect(throws: PDFReadError.unsupportedUserUnit) {
        try PDFFile(bytes: revisionFixture(extra: "/UserUnit \(unit)")).pages()
    }
    #expect(try PDFFile(bytes: revisionFixture(extra: "/UserUnit 1.0")).pages().count == 1)
}

@Test("An intentional crop survives an expanded incremental page")
func revisionPreservesCrop() throws {
    let original = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let output = original.appendingPathExtension("out")
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }
    try revisionFixture(extra: "/CropBox [10 15 90 85]").write(to: original)
    let grown = CGRect(x: -20, y: -10, width: 140, height: 130)
    try PDFOverlayWriter().write(original: original, overlays: [
        .init(pageIndex: 0, content: Data("0 g 0 0 10 10 re f".utf8), states: [], box: grown),
    ], to: output)
    let page = try #require(try PDFFile(url: output).pages().first)
    #expect(page.mediaBox == grown)
    #expect(page.cropBox == CGRect(x: 10, y: 15, width: 80, height: 70))
}
