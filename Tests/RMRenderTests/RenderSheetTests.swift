// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import PDFKit
import RMLines
@testable import RMRender
import Testing

// The sheet: page order, blanks, size, landscape.

@Test("Pages turn into a PDF")
func rendersPDF() throws {
    let page = try RMParser.parsePage(makePage())
    let pdf = try PageRenderer.pdf(pages: [page, page])

    #expect(!pdf.isEmpty)
    #expect(pdf.prefix(4) == Data("%PDF".utf8))
}

@Test("An empty notebook yields a file that opens, not zero bytes")
func rendersEmptyNotebook() throws {
    let pdf = try PageRenderer.pdf(pages: [])
    #expect(pdf.prefix(4) == Data("%PDF".utf8))
}

@Test("A page rasterises to a white bitmap of the scaled canvas, plus the band of a stroke on its edge")
func rendersPageImage() throws {
    // The fixture's first stroke starts on the top edge, so half its band
    // hangs over it: a bitmap keeps that band, and is taller by it.
    let page = try RMParser.parsePage(makePage())
    let image = try PageRenderer.image(page: page, scale: 0.5)
    let sheet = PageRenderer.contentBounds(of: page, pageSize: PageRenderer.defaultPageSize, edge: .uncut)
    #expect(sheet.width == PageRenderer.defaultPageSize.width)
    let canvas = PageRenderer.defaultPageSize.height
    #expect(sheet.height > canvas && sheet.height < canvas + 4)
    #expect(image.width == Int((sheet.width * 0.5).rounded()))
    #expect(image.height == Int((sheet.height * 0.5).rounded()))
}

@Test("A page stretched past its sheet rasterises tall enough to hold all its ink")
func rendersPageImageTallEnoughForAnExtendedPage() throws {
    // The tablet's "extend page" lets a notebook page grow well past the
    // normal sheet; a bitmap allocated at the plain sheet size simply never
    // has the pixels for what lies below it, and no OCR engine can read
    // pixels that were never drawn. `PageRenderer.image` has to grow the
    // same way the PDF path already does.
    let size = PageRenderer.defaultPageSize
    let page = RMPage(strokes: [stroke(points: [(0, 200), (0, 4118)])], skippedBlocks: 0)
    let bounds = PageRenderer.contentBounds(of: page, pageSize: size, edge: .uncut)
    let trimmed = PageRenderer.contentBounds(of: page, pageSize: size, edge: .ribbon)
    #expect(bounds == trimmed, "far past the edge, both agree")

    let image = try PageRenderer.image(page: page, pageSize: size)

    #expect(bounds.height > size.height, "the fixture must actually run past the sheet")
    #expect(
        CGFloat(image.height) == bounds.height.rounded(),
        "the bitmap must be exactly as tall as the ink needs, the same sheet a PDF page would get"
    )

    let data = try #require(image.dataProvider?.data as Data?)
    var ink = 0
    for pixel in stride(from: 0, to: data.count, by: 4) where data[pixel] < 250 {
        ink += 1
    }
    #expect(ink > 0, "the stroke must actually be drawn somewhere on the grown bitmap")
}

@Test("Ink a little under the edge is trimmed on the PDF's sheet, as the tablet trims it, and kept whole on a bitmap")
func bitmapKeepsInkTheTabletWouldTrim() throws {
    // Forty units below the sheet: the tablet's export leaves the sheet as
    // it was and cuts the overhang, and so does the PDF path. A bitmap is
    // read by an engine, and a last line written under the edge has to be
    // on it, foot and all.
    let size = PageRenderer.defaultPageSize
    let overhang: Float = 40
    let page = RMPage(strokes: [stroke(points: [(0, 1700), (0, Float(size.height) + overhang)])], skippedBlocks: 0)
    let trimmed = PageRenderer.contentBounds(of: page, pageSize: size, edge: .ribbon)
    #expect(trimmed.height == size.height, "the PDF's sheet stays the tablet's")
    let kept = PageRenderer.contentBounds(of: page, pageSize: size, edge: .uncut)
    let halfBand = CGFloat(stroke(points: [(0, 0)]).points[0].lineWidth) / 2
    let expected = size.height + CGFloat(overhang) + halfBand + 47
    #expect(abs(kept.height - expected) < 0.01, "the ink, its band and the foot")

    let image = try PageRenderer.image(page: page, pageSize: size)
    #expect(CGFloat(image.height) == kept.height.rounded())
    // The stroke's end lands inside the bitmap: a dark pixel in the rows
    // under the sheet's old edge.
    let data = try #require(image.dataProvider?.data as Data?)
    let bytesPerRow = image.bytesPerRow
    var inkBelowTheEdge = 0
    for row in Int(size.height)..<image.height {
        for column in 0..<image.width where data[row * bytesPerRow + column * 4] < 250 { inkBelowTheEdge += 1 }
    }
    #expect(inkBelowTheEdge > 0, "what hung over the edge is drawn, not cut")
}

@Test("A PDF names a creator and the person as its author, and no title")
func pdfCarriesAuthor() throws {
    let page = try RMParser.parsePage(makePage())
    let url = FileManager.default.temporaryDirectory.appending(path: "author-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try PageRenderer.pdf(pages: [page], author: "A. Writer", to: url)
    let attributes = try #require(PDFDocument(url: url)?.documentAttributes)
    #expect(attributes[PDFDocumentAttribute.authorAttribute] as? String == "A. Writer")
    #expect((attributes[PDFDocumentAttribute.creatorAttribute] as? String)?.isEmpty == false)
    #expect(attributes[PDFDocumentAttribute.titleAttribute] == nil, "a title would travel after a rename")
    try PageRenderer.pdf(pages: [page], to: url)
    #expect(PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
}

@Test("Coordinates map from the page centre into PDF space")
func convertsCoordinates() {
    let origin = PageRenderer.convert(StrokePoint(x: 0, y: 0, width: 1, pressure: 1))
    let lower = PageRenderer.convert(StrokePoint(x: 0, y: 100, width: 1, pressure: 1))

    #expect(origin.x == PageRenderer.defaultPageSize.width / 2, "zero x is the middle of the page")
    #expect(origin.y == PageRenderer.defaultPageSize.height, "zero y is the top of the page")
    #expect(lower.y < origin.y, "growing y on the tablet means moving down")
}

@Test("A page that fits keeps the page size")
func keepsPageSizeWhenContentFits() {
    let size = PageRenderer.defaultPageSize
    let inside = RMPage(strokes: [stroke(points: [(0, 100), (100, 200)])], skippedBlocks: 0)

    #expect(
        PageRenderer.contentBounds(of: inside, pageSize: size, edge: .ribbon) == CGRect(origin: .zero, size: size),
        "content inside the page must not grow it"
    )
}

@Test("The sheet grows to hold writing past the edges")
func sheetGrowsAroundContentDrawnOutsideThePage() {
    // A notebook canvas pans, and coordinates run past half the width: a
    // sheet of the plain page size would cut off the ends of such lines. The
    // tablet does not squeeze the page in this case, it shows a wider canvas
    // — so the sheet has to grow, keeping the scale one to one.
    let size = PageRenderer.defaultPageSize
    let overflowing = RMPage(
        strokes: [stroke(points: [(-716.5, 200), (775.2, 1281)])],
        skippedBlocks: 0
    )

    let bounds = PageRenderer.contentBounds(of: overflowing, pageSize: size, edge: .ribbon)
    #expect(bounds.minX < 0, "the leftmost stroke lies past the left edge")
    #expect(bounds.maxX > size.width, "the rightmost stroke lies past the right edge")
    #expect(bounds.width > size.width, "the sheet is wider than the page, not the page squeezed")
    #expect(bounds.height == size.height, "nothing sticks out vertically here, so the height holds")

    // And it grows to the square — side = the canvas height, centred on the
    // page — rather than to the ink's own extent. In an exported PDF, a page
    // whose ink stops short of the edge at ±987 and a page whose ink runs out
    // to +1559 are both exactly 2160 wide, the second with its far ink cut
    // off. So the width does not depend on how far
    // the pen went, only on whether it left the page.
    let square = max(size.width, size.height)
    #expect(abs(bounds.width - square) < 0.001)
    #expect(abs(bounds.minX - (size.width - square) / 2) < 0.001)

    // This stroke still lands on it: the square is wider than the page by more
    // than the stroke overhangs, so nothing here is what the tablet would cut.
    #expect(bounds.minX < CGFloat(Float(-716.5)) + size.width / 2)
    #expect(bounds.maxX > CGFloat(Float(775.2)) + size.width / 2)
}

@Test("The eraser does not stretch the sheet")
func eraserIsOutsideContentBounds() {
    let size = PageRenderer.defaultPageSize
    let erased = RMPage(
        strokes: [stroke(points: [(-5000, 100), (5000, 200)], tool: .eraser)],
        skippedBlocks: 0
    )

    #expect(
        PageRenderer.contentBounds(of: erased, pageSize: size, edge: .ribbon) == CGRect(origin: .zero, size: size),
        "the eraser is not drawn, so it has no business resizing the page"
    )
}

// MARK: - Page order

@Test("Page order is read from the new .content form")
func readsPageOrderV6() throws {
    let json = #"{"cPages":{"pages":[{"id":"page-b"},{"id":"page-a"}]}}"#
    #expect(try PageOrder.pages(from: Data(json.utf8)).map(\.id) == ["page-b", "page-a"])
}

@Test("The legacy .content form is understood too")
func readsPageOrderLegacy() throws {
    let json = #"{"pages":["page-1","page-2"]}"#
    #expect(try PageOrder.pages(from: Data(json.utf8)).map(\.id) == ["page-1", "page-2"])
}

// A relayout marks the spare records `deleted: {value: 1}` and leaves them in
// the list — an EPUB export carries 30 records for 9 living pages, each
// tombstone duplicating the `idx` and `redir` of a living one. Unfiltered,
// a host listing the document would show it three times its length.
@Test("Tombstoned pages are hidden; the living sort by idx")
func tombstonedPagesAreFilteredAndTheLivingSortByIdx() throws {
    let json = #"""
    {"cPages":{"pages":[
      {"id":"dead-1","idx":{"timestamp":"1:2","value":"ba"},
       "deleted":{"timestamp":"1:9","value":1}},
      {"id":"live-b","idx":{"timestamp":"1:2","value":"bb"}},
      {"id":"live-c","idx":{"timestamp":"1:2","value":"bc"}},
      {"id":"live-a","idx":{"timestamp":"1:2","value":"ba"}},
      {"id":"merged","idx":{"timestamp":"1:2","value":"bd"},
       "deleted":{"timestamp":"1:9","value":0}}
    ]}}
    """#
    let pages = try PageOrder.pages(from: Data(json.utf8))

    // The tombstone is gone; the record that survived a deletion (value 0)
    // is alive; and `live-a` stands first by its key, not last by its place
    // in the array.
    #expect(pages.map(\.id) == ["live-a", "live-b", "live-c", "merged"])
}

// A fractional key sorts between its neighbours the way the tablet mints it:
// a page inserted between "ba" and "bb" gets "bab".
@Test("A fractional idx key sorts between its neighbours")
func fractionalIdxSortsBetweenItsNeighbours() throws {
    let json = #"""
    {"cPages":{"pages":[
      {"id":"first","idx":{"timestamp":"1:2","value":"ba"}},
      {"id":"third","idx":{"timestamp":"1:2","value":"bb"}},
      {"id":"second","idx":{"timestamp":"1:2","value":"bab"}}
    ]}}
    """#
    #expect(
        try PageOrder.pages(from: Data(json.utf8)).map(\.id) == ["first", "second", "third"]
    )
}
// MARK: - Pages that were never drawn on

private func pageEntry(_ document: String, page: String, hash: String) -> DocumentFile {
    DocumentFile(hash: hash, name: "\(document)/\(page).rm", size: 10)
}

// A notebook nobody has written in must not throw
// `malformedPage("document has no pages")` — a caller could neither open
// it nor get past it. Its pages are in `.content`; what they lack is a
// `.rm` blob, which the tablet writes when the first stroke lands.
@Test("A page with no strokes keeps its place and its ruling")
func neverDrawnPagesStayInOrder() {
    let pages = [
        PageOrder.Page(id: "p1", template: "Grid", redir: nil),
        PageOrder.Page(id: "p2", template: "Lines", redir: nil),
        PageOrder.Page(id: "p3", template: nil, redir: nil),
    ]
    let entries = [pageEntry("doc", page: "p2", hash: "bb")]

    let order = NotebookRenderer.order(pages, entries: entries)

    #expect(order.count == 3, "a page nobody wrote on is a page, not a gap")
    #expect(order[0].entry == nil)
    #expect(order[0].template == "Grid", "the ruling is what makes it a sheet rather than a void")
    #expect(order[1].entry?.hash == "bb")
    #expect(order[2].entry == nil)
}

@Test("Strokes named by nothing in .content are kept, not dropped")
func strayPagesAreAppended() {
    let order = NotebookRenderer.order(
        [PageOrder.Page(id: "p1", template: nil, redir: nil)],
        entries: [
            pageEntry("doc", page: "p1", hash: "aa"),
            pageEntry("doc", page: "stray", hash: "zz"),
        ]
    )

    // Whatever the stray is, its strokes are the user's.
    #expect(order.count == 2)
    #expect(order[0].entry?.hash == "aa")
    #expect(order[1].entry?.hash == "zz")
}

@Test("A notebook with nothing written in it is all blank sheets")
func untouchedNotebookIsAllBlanks() {
    let order = NotebookRenderer.order(
        [
            PageOrder.Page(id: "p1", template: "Grid", redir: nil),
            PageOrder.Page(id: "p2", template: "Grid", redir: nil),
        ],
        entries: []
    )

    #expect(order.count == 2)
    #expect(order.allSatisfy { $0.entry == nil })
}

// The "as tablet" sheet is the sheet of *this* tablet.
//
// The canvas is declared in the page's own scene block and differs per
// model; one written-down sheet would fit exactly one of them. Canvas
// numbers.
private let modelCanvases: [(name: String, canvas: CGSize, sheet: CGSize)] = [
    ("ten-inch", CGSize(width: 1404, height: 1872), CGSize(width: 445.3, height: 593.8)),
    ("Paper Pro", CGSize(width: 1620, height: 2160), CGSize(width: 513.8, height: 685.1)),
    ("Paper Pro Move", CGSize(width: 820, height: 1458), CGSize(width: 260.1, height: 462.4)),
]

@Test("The tablet sheet follows the page canvas; the standard sheets do not")
func theTabletSheetFollowsThePageCanvas() {
    for model in modelCanvases {
        let sheet = PaperSize.tablet.points(forCanvas: model.canvas)
        #expect(abs(sheet.width - model.sheet.width) < 0.1, "\(model.name)")
        #expect(abs(sheet.height - model.sheet.height) < 0.1, "\(model.name)")
    }
    // A4 does not ask about the canvas: the page fits the standard, not
    // the other way round.
    let pro = modelCanvases[1].canvas
    #expect(PaperSize.a4.points(forCanvas: pro) == PaperSize.a4.points())
    #expect(PaperSize.letter.points(forCanvas: pro) == PaperSize.letter.points())
}

@Test("A landscape page comes out on the sheet the tablet's own export used")
func aLandscapePageMatchesTheTabletsExport() {
    // From the export, not derived. The reference is a landscape notebook exported
    // from the reMarkable app: its page carries `/MediaBox [0 0 685 514]` and
    // `/Rotate 0` — a sheet that is genuinely wider than it is tall, not an
    // upright one flagged to be turned by the reader.
    //
    // Divided by the `cm` matrix constant those points give the canvas back:
    // 685 / 0.317180616 = 2159.7 and 514 / 0.317180616 = 1620.4 — the Paper
    // Pro canvas of 1620×2160 lying on its side. Which settles the question
    // the templates could only hint at: a landscape document does not draw an
    // upright page and turn it at the end, it stands on a turned canvas.
    let turnedPro = CGSize(width: 2160, height: 1620)
    let sheet = PaperSize.tablet.points(forCanvas: turnedPro)

    #expect(abs(sheet.width - 685) < 0.5, "the export's MediaBox is 685 wide, ours is \(sheet.width)")
    #expect(abs(sheet.height - 514) < 0.5, "the export's MediaBox is 514 tall, ours is \(sheet.height)")
    #expect(sheet.width > sheet.height)

    // And it is the upright Pro sheet with its sides exchanged — the same
    // paper, turned, rather than a second sheet of some other size.
    let upright = PaperSize.tablet.points(forCanvas: modelCanvases[1].canvas)
    #expect(abs(sheet.width - upright.height) < 0.01)
    #expect(abs(sheet.height - upright.width) < 0.01)
}

@Test("An empty Pro page comes out on a Pro sheet, not a ten-inch one")
func aProPageIsDrawnOnAProSheet() throws {
    for model in modelCanvases {
        let data = try PageRenderer.pdf(
            pages: [RMPage(strokes: [], skippedBlocks: 0)],
            pageSize: model.canvas,
            paper: .tablet
        )
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        // Rounded, because the tablet's own box is: all 23 different page
        // boxes in a Move export of the corpus are whole numbers of points,
        // and each is its sheet in units times the unit, rounded — a Move's
        // 1458.303 units come back as 463 points and not as 462.4.
        #expect(abs(box.width - model.sheet.width.rounded()) < 0.01, "\(model.name): \(box)")
        #expect(abs(box.height - model.sheet.height.rounded()) < 0.01, "\(model.name): \(box)")
    }
}

// MARK: - Landscape documents

@Test("The document's own orientation switch is read, in either shape")
func contentOrientationIsRead() throws {
    // The tablet writes the field plainly, beside the reader settings. Its
    // neighbours in the same file come wrapped in a timestamp, so the reader
    // takes both shapes rather than returning a silent nil and drawing the
    // page the wrong way round.
    func layout(_ orientation: String) throws -> PageOrder.Layout {
        try PageOrder.layout(from: Data("""
        {
            "orientation": \(orientation),
            "cPages": { "pages": [ { "id": "a", "idx": { "value": "ba" } } ] }
        }
        """.utf8))
    }

    #expect(try layout("\"landscape\"").isLandscape)
    #expect(try !layout("\"portrait\"").isLandscape)
    #expect(try layout("{ \"timestamp\": \"2:1\", \"value\": \"landscape\" }").isLandscape)
    // Absent means upright: a notebook written with the tablet held sideways
    // records nothing at all.
    #expect(try !PageOrder.layout(from: Data("""
    { "cPages": { "pages": [ { "id": "a" } ] } }
    """.utf8)).isLandscape)
}

@Test("A landscape document stands on a canvas laid on its side")
func landscapeCanvasIsTurned() {
    let portrait = CGSize(width: 1404, height: 1872)
    let landscape = CGSize(width: 1872, height: 1404)

    // Nothing declared: the default is upright and has to be turned over.
    #expect(NotebookRenderer.canvas(declared: nil, isLandscape: true) == landscape)
    #expect(NotebookRenderer.canvas(declared: nil, isLandscape: false) == portrait)
    // Declared upright by a document that says landscape: turned.
    #expect(NotebookRenderer.canvas(declared: portrait, isLandscape: true) == landscape)
    // Declared on its side already: left alone rather than turned twice.
    #expect(NotebookRenderer.canvas(declared: landscape, isLandscape: true) == landscape)
    // An upright document keeps whatever it declared, sideways or not — the
    // declaration is the document's, and second-guessing it here would undo a
    // size the tablet meant.
    #expect(NotebookRenderer.canvas(declared: landscape, isLandscape: false) == landscape)
}

@Test("A standard sheet turns with the page instead of shrinking it to a band")
func standardSheetTurnsWithTheCanvas() {
    let landscape = CGSize(width: 1872, height: 1404)
    let portrait = CGSize(width: 1404, height: 1872)

    let upright = PaperSize.a4.points(forCanvas: portrait)
    let turned = PaperSize.a4.points(forCanvas: landscape)
    #expect(turned.width == upright.height && turned.height == upright.width)
    #expect(turned.width > turned.height)

    let letter = PaperSize.letter.points(forCanvas: landscape)
    #expect(letter.width == 792 && letter.height == 612)

    // The tablet sheet is the canvas expressed in points; it arrives on its
    // side and must not be turned a second time.
    let tablet = PaperSize.tablet.points(forCanvas: landscape)
    #expect(tablet.width > tablet.height)
}

@Test("A landscape template drawn on a turned canvas puts its content on the page")
func landscapeTemplateFitsTheTurnedCanvas() throws {
    // `Fixture Wide Staves` writes its horizontals out as plain numbers
    // rather than fractions of `templateWidth`, so it cannot adapt: its
    // staves reach x = 1743. On the upright 1404-wide page they would run off
    // the right edge.
    let template = try #require(FixtureTemplates.store.template(named: "Fixture Wide Staves"))
    #expect(template.isLandscape)

    let width = 1872
    let height = 1404
    let (context, pixels) = try probeCanvas(width: width, height: height)
    TemplateRenderer.draw(template, in: context, size: CGSize(width: width, height: height))

    let columns = (0..<width).filter { x in
        stride(from: 0, to: height, by: 4).contains { pixels[$0 * width + x] < 250 }
    }
    let rightmost = try #require(columns.max())
    #expect(rightmost > 1404, "the staves must reach past where an upright page would end, at \(rightmost)")
    #expect(rightmost < width, "and still stand on the page, at \(rightmost)")
}

// Ink past one edge only. The square is the window the tablet's export
// opens on such a page, and its apps on every model show the page centred
// on it: the margin on the side the pen never crossed is the window's own,
// not a half-band hanging over to be cut off. Cut, a Move page written a
// few units past its right edge came out 1139 wide with the canvas pressed
// to the left, where the tablet shows it centred on 1458.
@Test("Ink past one edge alone still centres the page on the square")
func oneSidedOverflowStillCentres() {
    let size = CGSize(width: 820, height: 1458)
    let overflowing = RMPage(
        strokes: [stroke(points: [(-405, 900), (415, 1000)])],
        skippedBlocks: 0
    )
    let bounds = PageRenderer.contentBounds(of: overflowing, pageSize: size, edge: .ribbon)
    #expect(abs(bounds.width - size.height) < 0.001, "the square: \(bounds.width)")
    #expect(abs(bounds.minX - (size.width - size.height) / 2) < 0.001, "centred: \(bounds.minX)")

    // The top keeps its own rule on such a page: a stroke that starts on
    // the first unit hangs half a band above the sheet, and the sheet does
    // not grow for it: squaring the width leaves the top alone.
    let alongTheTop = RMPage(
        strokes: [stroke(points: [(-405, 0), (415, 0)])],
        skippedBlocks: 0
    )
    let top = PageRenderer.contentBounds(of: alongTheTop, pageSize: size, edge: .ribbon)
    #expect(abs(top.width - size.height) < 0.001)
    #expect(abs(top.maxY - size.height) < 0.001, "the top holds: \(top.maxY)")
}
