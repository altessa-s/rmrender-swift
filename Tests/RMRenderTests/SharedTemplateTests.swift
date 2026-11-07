// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import RMLines
import Testing

// A notebook's templates drawn once and shared (`PageRenderer.PDFPages`): the
// pages that draw a template alike start with one Form of it, CoreGraphics
// leaves it out of them, and every page paints what CoreGraphics drawing it
// whole paints.

private let pageSize = CGSize(width: 1404, height: 1872)

/// A stroke that runs `below` units past the page's bottom edge, so that
/// the sheet grows and the template's transform and extent with it.
private func strokeBelow(_ below: Double) -> Stroke {
    Stroke(tool: .fineliner2, color: .black, thicknessScale: 1, points: [
        StrokePoint(x: -200, y: 1700, width: 8, pressure: 1),
        StrokePoint(x: 100, y: Float(1872 + below), width: 8, pressure: 1),
    ])
}

/// Pages on four templates: some with nothing else, some with typed text,
/// highlights and ink, some grown below the edge — two of them alike, one
/// on its own — and one that hides its template.
private func templatedNotebook() -> [RMPage] {
    _ = FixtureTemplates.installed
    var marks = Marks(random: SplitMix64(seed: 0x7E3B))
    let templates = ["Fixture Dots", "Fixture Grid", "Fixture Week", "Fixture Lines"]
    var pages: [RMPage] = []
    for index in 0..<20 {
        let template = templates[index % templates.count]
        switch index % 5 {
        case 0: pages.append(RMPage(strokes: [], skippedBlocks: 0, templateName: template))
        case 1: pages.append(marks.page(strokes: 20, text: true, template: template))
        case 2: pages.append(marks.page(strokes: 0, blankText: [""], template: template, highlights: 3))
        case 3: pages.append(RMPage(strokes: [strokeBelow(400)], skippedBlocks: 0, templateName: "Fixture Dots"))
        default: pages.append(marks.page(strokes: 25, pictures: index.isMultiple(of: 2), template: template))
        }
    }
    pages.append(RMPage(strokes: [strokeBelow(900)], skippedBlocks: 0, templateName: "Fixture Dots"))
    pages.append(RMPage(strokes: [], skippedBlocks: 0, templateName: "Fixture Dots", backgroundVisible: false))
    return pages
}

/// How many pages of `pdf` start with a shared template, and how many
/// shared templates there are.
private func sharing(in pdf: Data) throws -> (pages: Int, templates: Int) {
    let file = try PDFFile(bytes: pdf)
    var forms: Set<Int> = []
    var pages = 0
    for page in try file.pages() {
        let resources = try file.resolve(page.resources).dictionaryValue ?? [:]
        let objects = try file.resolve(resources["XObject"]).dictionaryValue ?? [:]
        guard case .reference(let number, _) = objects[InkUpdate.templateName] else { continue }
        pages += 1
        forms.insert(number)
    }
    return (pages, forms.count)
}

@Test("Pages that draw a template alike share one drawing of it, and paint as CoreGraphics drawing each page does")
func sharedTemplatesPaintAsCoreGraphicsDoes() throws {
    let pages = templatedNotebook()
    let assets = ["picture.png": testPicture()]
    let written = try PageRenderer.pdf(pages: pages, pageSize: pageSize, assets: assets)
    let native = try InkTesting.allCoreGraphics(pages: pages, pageSize: pageSize, assets: assets)
    // Every template drawn alike on more than one page — the same template
    // on the same sheet under the same placement — is drawn by CoreGraphics
    // on the first of them and shared from the second on; a page grown on
    // its own, and the page that hides its template, draw their own.
    var alike: [String: Int] = [:]
    let scale = PaperSize.a4.points(forCanvas: pageSize).width / pageSize.width
    for page in pages where page.backgroundVisible {
        let geometry = page.text.map { TextGeometry($0, pageSize: pageSize) }
        let bounds = PageRenderer.contentBounds(of: page, pageSize: pageSize, edge: .ribbon, geometry: geometry)
        let sheet = PageRenderer.grownSheet(from: bounds, floor: PaperSize.a4.points(forCanvas: pageSize), scale: scale)
        alike["\(page.templateName ?? "") \(bounds) \(sheet)", default: 0] += 1
    }
    let shared = try sharing(in: written)
    #expect(shared.templates == alike.values.filter { $0 > 1 }.count, "\(shared)")
    #expect(shared.pages == alike.values.reduce(0) { $0 + max($1 - 1, 0) }, "\(shared)")
    // The four templates on the paper's own sheet and the dots grown alike.
    #expect(shared.templates >= 5)
    #expect(written.count < native.count)
    for number in 1...pages.count {
        for scale in [0.5, 1, 2.5, 6.25] {
            #expect(try InkTesting.differingPixels(native, written, page: number, scale: scale) == 0, "page \(number) at \(scale)")
        }
    }
}

@Test("A shared template leaves CoreGraphics' drawing of the rest of the page as it starts without one")
func sharedTemplateIsDrawnFirst() throws {
    _ = FixtureTemplates.installed
    let page = RMPage(strokes: [], skippedBlocks: 0, templateName: "Fixture Grid")
    let written = try PageRenderer.pdf(pages: [page, page], pageSize: pageSize)
    let file = try PDFFile(bytes: written)
    let second = try file.pages()[1]
    let contents = try #require(try file.resolve(second.dictionary["Contents"]).arrayValue)
    // The template's Form first, then CoreGraphics' own drawing of the page.
    guard case .stream(let dictionary, let bytes) = try file.resolve(contents.first) else {
        Issue.record("the page's first content is not a stream")
        return
    }
    #expect(try file.decode(dictionary, bytes) == Data("/\(InkUpdate.templateName) Do\n".utf8))
    // The first page draws its own, as it always did; the second does not.
    #expect(try sharing(in: written) == (pages: 1, templates: 1))
    let first = try InkTesting.content(of: written, page: 1)
    let rest = try InkTesting.content(of: written, page: 2)
    #expect(first.count > rest.count + 1000)
}
