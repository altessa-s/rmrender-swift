// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import Foundation
@testable import RMRender
import Testing

private let ownStream = "q\n% endstream inside the payload\nQ\n"
private func lengthFixture(length: String = "5 0 R", values: [Int: String] = [:]) -> Data {
    var objects = [
        1: "<< /Type /Catalog /Pages 2 0 R >>",
        2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>",
        4: "<< /Length \(length) >>\nstream\n\(ownStream)endstream",
        5: String(ownStream.utf8.count),
    ]
    objects.merge(values) { _, new in new }
    var data = Data("%PDF-1.4\n".utf8), offsets: [Int: Int] = [:]
    for number in objects.keys.sorted() {
        offsets[number] = data.count
        data.append(Data("\(number) 0 obj\n\(objects[number] ?? "null")\nendobj\n".utf8))
    }
    let xref = data.count, count = (objects.keys.max() ?? 0) + 1
    data.append(Data("xref\n0 \(count)\n0000000000 65535 f \n".utf8))
    for number in 1..<count {
        data.append(Data(String(format: "%010d 00000 %@ \n", offsets[number] ?? 0,
                               offsets[number] == nil ? "f" : "n").utf8))
    }
    data.append(Data("trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return data
}

@Test("Indirect stream length follows generation-checked references and counts exact bytes")
func indirectStreamLength() throws {
    let file = try PDFFile(bytes: lengthFixture(values: [5: "6 0 R", 6: String(ownStream.utf8.count)]))
    guard case .stream(_, let data) = try file.object(4) else {
        Issue.record("Expected a stream")
        return
    }
    #expect(data == Data(ownStream.utf8))
}

@Test("Invalid indirect stream lengths fail without recursion or overflow")
func invalidIndirectLengths() throws {
    let fixtures = [
        lengthFixture(length: "5 1 R"), lengthFixture(length: "99 0 R"),
        lengthFixture(length: "4 0 R"),
        lengthFixture(values: [5: "6 0 R", 6: "5 0 R"]),
        lengthFixture(values: [5: "0"]), lengthFixture(values: [5: "2"]),
        lengthFixture(values: [5: "-1"]), lengthFixture(values: [5: "null"]),
        lengthFixture(values: [5: String(Int.max)]),
    ]
    for bytes in fixtures {
        #expect(throws: PDFReadError.self) { try PDFFile(bytes: bytes).object(4) }
    }
    var deep: [Int: String] = [:]
    for number in 5..<80 { deep[number] = "\(number + 1) 0 R" }
    deep[80] = String(ownStream.utf8.count)
    #expect(throws: PDFReadError.self) { try PDFFile(bytes: lengthFixture(values: deep)).object(4) }
}

@Test("A document with indirect content length can be updated twice without redrawing")
func indirectLengthUpdate() throws {
    let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let output = source.appendingPathExtension("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: output)
    }
    try lengthFixture().write(to: source)
    for _ in 0..<2 {
        let before = try Data(contentsOf: source)
        try PDFOverlayWriter().write(original: source, overlays: [
            .init(pageIndex: 0, content: Data("0 g 20 20 10 10 re f".utf8), states: []),
        ], to: output)
        #expect(try Data(contentsOf: output).starts(with: before))
        #expect(try PDFFile(url: output).pages().count == 1)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: output, to: source)
    }
}
