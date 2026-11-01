// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import PDFKit
import RMLines
@testable import RMRender
import Testing

@Test("Deleted page files are excluded from index recovery", arguments: [false, true])
func deletedPagesStayDeleted(hasLivingPage: Bool) async throws {
    var records: [[String: Any]] = [["id": "gone", "deleted": ["value": 1]]]
    if hasLivingPage { records.append(["id": "live", "deleted": ["value": 0]]) }
    let content = try JSONSerialization.data(withJSONObject: ["cPages": ["pages": records]])
    let blobs = RegressionBlobs(values: ["content": content])
    let names = hasLivingPage ? ["gone", "live", "orphan"] : ["gone"]
    let entries = names.map { DocumentFile(hash: $0, name: "document/\($0).rm", size: 1) }
    let index = DocumentFiles(files: entries + [
        DocumentFile(hash: "content", name: "document.content", size: Int64(content.count))
    ])
    let renderer = NotebookRenderer(blobs: blobs)
    let pages = await renderer.orderedPages(index: index)
    #expect(pages.compactMap { $0.entry?.fileBaseName } == (hasLivingPage ? ["live", "orphan"] : []))
    if !hasLivingPage {
        let parsed = try await renderer.parsed(documentID: "document", index: index)
        #expect(parsed.pages.count == 1)
        #expect(parsed.pages[0].skippedBlocks == 0)
        #expect(parsed.unreadable.isEmpty)
    }
}

// An edit made later goes to a page's own file, not to its place in the
// document: the parse names each page by that file, in reading order, and
// a page never drawn on — listed, with no file — by nothing.
@Test func aParsedNotebookNamesEachPageByItsFile() async throws {
    let draft = RMPageDraft(
        author: UUID(),
        sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
        column: .init(.medium), paragraphs: [.init("x")]
    )
    let page = try RMWriter.page(draft)
    let records: [[String: Any]] = [
        ["id": "second", "idx": ["value": "ba"]],
        ["id": "blank", "idx": ["value": "bb"]],
        ["id": "first", "idx": ["value": "aa"]],
    ]
    let content = try JSONSerialization.data(withJSONObject: ["cPages": ["pages": records]])
    let blobs = RegressionBlobs(values: ["content": content, "first": page, "second": page])
    let index = DocumentFiles(files: [
        DocumentFile(hash: "first", name: "document/first.rm", size: Int64(page.count)),
        DocumentFile(hash: "second", name: "document/second.rm", size: Int64(page.count)),
        DocumentFile(hash: "content", name: "document.content", size: Int64(content.count)),
    ])
    let parsed = try await NotebookRenderer(blobs: blobs).parsed(documentID: "document", index: index)
    #expect(parsed.pageIDs == ["first", "second", nil])
    #expect(parsed.pageIDs.count == parsed.pages.count)
}

private struct RegressionBlobs: PageBlobs {
    let values: [String: Data]
    func data(hash: String, name: String, owner: String?) async throws -> Data {
        try #require(values[hash])
    }
    func file(
        hash: String, name: String, owner: String?, size: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> BlobFile {
        let url = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).pdf")
        try await data(hash: hash, name: name, owner: owner).write(to: url)
        return BlobFile(url: url, isTemporary: true)
    }
}

@Test func textOnlyAnnotationsSurviveOverlay() async throws {
    let original = try PageRenderer.pdf(pages: [RMPage(strokes: [], skippedBlocks: 0)])
    let draft = RMPageDraft(
        author: UUID(),
        sheet: .init(screenWidth: 1404, screenHeight: 1872, canvasWidth: 1404, canvasHeight: 1872),
        column: .init(.medium), paragraphs: [.init("AUDITVISIBLE")]
    )
    let page = try RMWriter.page(draft)
    let content = Data(#"{"pages":["page"],"redirectionPageMap":[0]}"#.utf8)
    let blobs = RegressionBlobs(values: ["pdf": original, "rm": page, "content": content])
    let index = DocumentFiles(files: [
        DocumentFile(hash: "pdf", name: "document.pdf", size: Int64(original.count)),
        DocumentFile(hash: "rm", name: "page.rm", size: Int64(page.count)),
        DocumentFile(hash: "content", name: "document.content", size: Int64(content.count))
    ])
    let output = FileManager.default.temporaryDirectory.appending(path: "overlay-audit-\(UUID()).pdf")
    defer { try? FileManager.default.removeItem(at: output) }
    let renderer = AnnotatedPDFRenderer(blobs: blobs)
    try await renderer.renderPDF(documentID: "document", index: index, to: output, allowOverlay: false)
    #expect(PDFDocument(url: output)?.string?.contains("AUDITVISIBLE") == true)
    try await renderer.renderPDF(documentID: "document", index: index, to: output)
    #expect(PDFDocument(url: output)?.string?.contains("AUDITVISIBLE") == true)
}
