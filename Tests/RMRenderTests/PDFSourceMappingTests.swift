// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Darwin
import Foundation
@testable import RMRender
import Testing

// The original of an annotated document is read where it lies: a file is
// mapped rather than read into memory, and the copy an overlay is appended to
// goes file to file. What these guard is that the mapped and the in-memory
// readings write the same bytes, that a file opened by URL really is a
// mapping of that file, and that the copy costs no memory of its own.

// MARK: - Fixtures

private func temporaryURL(_ suffix: String = "pdf") -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rmrender-source-\(UUID().uuidString).\(suffix)")
}

private func smallPDF(pages: Int) throws -> Data {
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for page in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.4, alpha: 1)
        context.fill(CGRect(x: 10 + page * 3, y: 10, width: 40, height: 40))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// The real path of the file a page of this process's memory is mapped from,
/// or `nil` where the page is not a file's.
private func mappedFile(at address: UnsafeRawPointer?) -> String? {
    guard let address else { return nil }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_regionfilename(getpid(), UInt64(UInt(bitPattern: address)), &path, UInt32(path.count))
    guard length > 0 else { return nil }
    return String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The path as the kernel names it: `/private/var/…` where Foundation says
/// `/var/…`, which `resolvingSymlinksInPath` strips again.
private func realPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The process's footprint as the system counts it against a memory limit:
/// dirty and compressed memory, not the clean pages of a mapped file.
private func footprint() -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

/// A PDF of one page with an unreferenced stream of `padding` zeros in the
/// middle: as big on paper as a scanned book, written without a byte of it in
/// memory — the zeros are a hole the file system leaves unwritten.
private func paddedPDF(at url: URL, padding: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var offsets: [Int] = []
    var position = 0
    func put(_ text: String) throws {
        let bytes = Data(text.utf8)
        try handle.write(contentsOf: bytes)
        position += bytes.count
    }
    try put("%PDF-1.4\n")
    offsets.append(position)
    try put("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
    offsets.append(position)
    try put("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
    offsets.append(position)
    try put("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>\nendobj\n")
    offsets.append(position)
    try put("4 0 obj\n<< /Length \(padding) >>\nstream\n")
    position += padding
    try handle.truncate(atOffset: UInt64(position))
    try handle.seekToEnd()
    try put("\nendstream\nendobj\n")
    let crossReference = position
    var table = "xref\n0 5\n0000000000 65535 f \n"
    for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
    try put(table + "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(crossReference)\n%%EOF\n")
}

private let mark = PDFOverlayWriter.Overlay(
    pageIndex: 0, content: Data("0 0 1 RG 4 w 20 20 m 200 300 l S\n".utf8), states: []
)

// MARK: - Tests

@Test("An original read by URL and one handed over as bytes give the same overlay, byte for byte")
func mappedAndInMemoryOriginalsWriteTheSame() throws {
    let original = temporaryURL()
    let fromFile = temporaryURL()
    let fromBytes = temporaryURL()
    defer {
        for url in [original, fromFile, fromBytes] { try? FileManager.default.removeItem(at: url) }
    }
    try smallPDF(pages: 5).write(to: original)
    let overlays = [0, 2, 4].map {
        PDFOverlayWriter.Overlay(pageIndex: $0, content: mark.content, states: [], box: CGRect(x: -20, y: 0, width: 340, height: 400))
    }

    let mapped = try PDFFile(url: original)
    try PDFOverlayWriter().write(file: mapped, pages: try mapped.pages(), original: original, overlays: overlays, to: fromFile)
    let held = try PDFFile(bytes: Data(contentsOf: original))
    try PDFOverlayWriter().write(file: held, pages: try held.pages(), original: original, overlays: overlays, to: fromBytes)

    let written = try Data(contentsOf: fromFile)
    #expect(written == (try Data(contentsOf: fromBytes)))
    #expect(written.count > (try Data(contentsOf: original)).count)
}

@Test("A file opened by URL is read through a mapping of that file; bytes handed over are not")
func originalByURLIsMapped() throws {
    let original = temporaryURL()
    defer { try? FileManager.default.removeItem(at: original) }
    try smallPDF(pages: 3).write(to: original)

    let mapped = try PDFFile(url: original)
    let region = mapped.bytes.withUnsafeBytes { mappedFile(at: $0.baseAddress) }
    #expect(region == realPath(original))

    let held = try PDFFile(bytes: Data(contentsOf: original))
    let heldRegion = held.bytes.withUnsafeBytes { mappedFile(at: $0.baseAddress) }
    #expect(heldRegion != realPath(original))

    // An empty file maps to nothing and is still refused for what it is.
    let empty = temporaryURL()
    defer { try? FileManager.default.removeItem(at: empty) }
    FileManager.default.createFile(atPath: empty.path, contents: nil)
    #expect(throws: PDFReadError.notAPDF) { try PDFFile(url: empty) }
}

@Test("Overlaying a large original costs no memory the size of it: the copy goes file to file")
func overlayCopyDoesNotLoadTheOriginal() throws {
    let padding = 384 << 20
    let original = temporaryURL()
    let output = temporaryURL()
    defer {
        try? FileManager.default.removeItem(at: original)
        try? FileManager.default.removeItem(at: output)
    }
    try paddedPDF(at: original, padding: padding)
    let originalSize = try #require(FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int)
    #expect(originalSize > padding)

    let before = footprint()
    try PDFOverlayWriter().write(original: original, overlays: [mark], to: output)
    let grown = Int64(footprint()) - Int64(before)

    let outputSize = try #require(FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
    #expect(outputSize > originalSize)
    // Held whole — read and written back, or mapped and dirtied — the
    // original would cost its own 384 MB. Other tests run beside this one, so
    // the bound leaves them room and still catches that.
    #expect(grown < Int64(padding / 2), "footprint grew by \(grown >> 20) MB")
}
