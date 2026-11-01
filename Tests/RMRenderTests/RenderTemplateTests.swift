// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines
@testable import RMRender
import Testing

// Templates: where they come from, the drawing environment, every fixture.

@Test("The template name is taken out of its timestamped wrapper")
func readsPageTemplate() throws {
    // Values in .content are wrapped: {"timestamp": "2:1", "value": "…"}.
    let json = #"""
    {"cPages":{"pages":[
      {"id":"page-a","template":{"timestamp":"2:1","value":"P US Legal"}},
      {"id":"page-b"}
    ]}}
    """#
    let pages = try PageOrder.pages(from: Data(json.utf8))

    #expect(pages.first?.template == "P US Legal")
    #expect(pages.last?.template == nil, "a page without a template is normal")
}

@Test("A store with no source knows no template")
func storeWithoutSourceIsBlank() {
    let store = TemplateStore(source: nil)
    #expect(store.availableNames().isEmpty)
    #expect(store.template(named: "Fixture Lines") == nil)
    #expect(store.ruledTemplates(pageSize: PageRenderer.defaultPageSize).isEmpty)
}

@Test("A store lists and parses what its source supplies")
func storeReadsItsSource() throws {
    let store = FixtureTemplates.store
    #expect(store.availableNames() == FixtureTemplates.all.keys.sorted())
    let lines = try #require(store.template(named: "Fixture Lines"))
    #expect(lines.name == "Lines")
    #expect(lines.categories == ["Lines"])
    #expect(!lines.items.isEmpty)
    #expect(store.template(named: "no such template") == nil)
}

@Test("A template that does not parse is no template, not a failure")
func unparsableTemplateIsAbsent() {
    struct Broken: TemplateSource {
        func templateNames() -> [String] { ["Broken"] }
        func templateData(named name: String) -> Data? { Data("{\"name\": 3}".utf8) }
    }
    #expect(TemplateStore(source: Broken()).template(named: "Broken") == nil)
}

@Test("A directory source reads `<name>.template` files and nothing outside them")
func directorySourceReadsFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rmrender-templates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["Fixture Lines", "Fixture Grid"] {
        let json = try #require(FixtureTemplates.all[name])
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(name).template"))
    }
    try Data("not a template".utf8).write(to: directory.appendingPathComponent("notes.txt"))

    let source = TemplateDirectory(url: directory)
    #expect(source.templateNames() == ["Fixture Grid", "Fixture Lines"])
    #expect(source.templateData(named: "../Fixture Lines") == nil)
    #expect(source.templateData(named: "notes") == nil)

    let store = TemplateStore(source: source)
    #expect(store.template(named: "Fixture Grid")?.categories == ["Grids"])
}

@Test("A template changes the page image, and an unknown one leaves it blank")
func templateChangesRendering() throws {
    _ = FixtureTemplates.installed
    let blank = RMPage(strokes: [], skippedBlocks: 0)
    let lined = blank.with(templateName: "Fixture Lines")
    let unknown = blank.with(templateName: "no such template")

    let withoutTemplate = try PageRenderer.pdf(pages: [blank])
    let withTemplate = try PageRenderer.pdf(pages: [lined])
    #expect(withTemplate.count > withoutTemplate.count, "template lines must reach the PDF")

    func pixels(_ page: RMPage) throws -> Data {
        let image = try PageRenderer.image(page: page)
        return try #require(image.dataProvider?.data as Data?)
    }
    #expect(try pixels(unknown) == pixels(blank), "an unknown template draws nothing")
}

@Test("A grid anchored to the sheet square lands where the formula puts it")
func sheetAnchoredColumnsPhase() throws {
    // `Fixture Columns` stands one vertical at the left edge of a 58.4-unit
    // cell that starts at `paperOriginX - cell / 2`. On a 1620×2160 page
    // `paperOriginX` is (1620 − 2160) / 2 = −270, so the family stands at
    // −299.2 + k · 58.4: at 51.2 modulo the cell. With `paperOriginX`
    // missing from the environment the phase would be 29.2.
    let template = try #require(FixtureTemplates.store.template(named: "Fixture Columns"))

    let width = 1620
    let height = 2160
    let (context, pixels) = try probeCanvas(width: width, height: height)
    TemplateRenderer.draw(template, in: context, size: CGSize(width: width, height: height))

    var darkestColumn = 0
    var darkestSum = Int.max
    for x in 0..<width {
        var sum = 0
        for y in stride(from: 0, to: height, by: 4) {
            sum += Int(pixels[y * width + x])
        }
        if sum < darkestSum {
            darkestSum = sum
            darkestColumn = x
        }
    }

    let phase = Double(darkestColumn).truncatingRemainder(dividingBy: 58.4)
    let offset = abs(phase - 51.2)
    let distance = min(offset, 58.4 - offset)
    #expect(distance <= 2, "vertical family at \(phase), the formula puts it at 51.2")
}

@Test("A planner's day names are centred in their columns, not stacked on the left")
func templateTextWidthCentresLabels() throws {
    // `Fixture Week` places every day name at `k.5 * templateWidth / 7 -
    // textWidth / 2`. `textWidth` is the label's own width; with the name
    // missing the expression fails and the fallback puts all seven names at
    // x = 0. Saturday's column centre is where no rule is drawn, so ink
    // there can only be the label.
    let template = try #require(FixtureTemplates.store.template(named: "Fixture Week"))

    let width = 2160
    let height = 1620
    let (context, pixels) = try probeCanvas(width: width, height: height)
    TemplateRenderer.draw(template, in: context, size: CGSize(width: width, height: height))

    // The labels sit on the baseline at y = 200 counted from the top, so the
    // glyphs occupy the band just above it. A bitmap row is that same y: the
    // first row of the buffer is the top of the image.
    func ink(from left: Int, to right: Int) -> Int {
        var count = 0
        for y in 165..<202 {
            for x in left..<right where pixels[y * width + x] < 235 {
                count += 1
            }
        }
        return count
    }

    let saturday = Int(6.5 * Double(width) / 7)
    #expect(ink(from: saturday - 80, to: saturday + 80) > 50, "Saturday must be centred in the last column")
    // Sunday's own column starts at zero, so the left edge is not empty — but
    // seven names piled up there are far more ink than one rule.
    #expect(ink(from: 0, to: 40) < 200, "the labels must not be stacked on the left edge")
}
// MARK: - The template environment, and what it cannot supply

/// A template written out here rather than taken from the fixtures: these tests
/// are about the environment the renderer offers, and a probe that draws one
/// line at one name says that far more plainly than a planner does.
private func probeTemplate(_ json: String) throws -> Template {
    try JSONDecoder().decode(Template.self, from: Data(json.utf8))
}

@Test("The sheet origin is the square's edge, not a constant offset")
func paperOriginFollowsTheSheetSquare() throws {
    // Two horizontals, each pinned to one of the names the evaluator supplies:
    // `paperOriginX` mirrored into view (it is negative — the sheet square is
    // wider than the canvas) and `paperOriginY` pushed down by 300.
    //
    // On 1404×1872 — `PageRenderer.defaultPageSize` — the template formula
    // puts the first line at y = 234. A constant offset such as
    // `width / 2 - 613.2` gives +88.8, whose mirror is off the top of the
    // page: that line would not be drawn at all. And with `paperOriginY`
    // absent the second expression fails and falls back to zero, which is the
    // top edge rather than y = 300. Either regression moves a line this test
    // can see.
    let template = try probeTemplate("""
    {
        "name": "OriginProbe",
        "items": [
            {"type": "path", "data": ["M", 0, "0 - paperOriginX", "L", "templateWidth", "0 - paperOriginX"]},
            {"type": "path", "data": ["M", 0, "paperOriginY + 300", "L", "templateWidth", "paperOriginY + 300"]}
        ]
    }
    """)

    let width = 1404
    let height = 1872
    let (context, pixels) = try probeCanvas(width: width, height: height)
    let problems = TemplateRenderer.drawReportingProblems(
        template,
        in: context,
        size: CGSize(width: width, height: height)
    )

    #expect(problems.messages.isEmpty, "both names must resolve: \(problems.messages.sorted())")

    let rows = inkedRows(pixels, width: width, height: height)
    let expected = [233, 299]
    for target in expected {
        let nearest = try #require(rows.min(by: { abs($0 - target) < abs($1 - target) }))
        #expect(abs(nearest - target) <= 3, "no line near \(target); inked rows \(rows)")
    }
    #expect(
        rows.allSatisfy { row in expected.contains { abs(row - $0) <= 3 } },
        "ink outside the two probed lines: \(rows)"
    )
}

@Test("A one-letter constant is a coordinate, not a path command")
func singleLetterConstantIsACoordinate() throws {
    // A template may declare constants named `h` and `w`. Taking every single
    // letter for a command means a bare `w` where a coordinate belongs is
    // eaten and the path comes out empty.
    let template = try probeTemplate("""
    {
        "name": "SingleLetterProbe",
        "constants": [{ "w": 500 }],
        "items": [
            {"type": "path", "data": ["M", "w", 100, "L", "w", 800]}
        ]
    }
    """)

    let width = 1000
    let height = 1000
    let (context, pixels) = try probeCanvas(width: width, height: height)
    let problems = TemplateRenderer.drawReportingProblems(
        template,
        in: context,
        size: CGSize(width: width, height: height)
    )

    #expect(problems.messages.isEmpty, "nothing was swallowed: \(problems.messages.sorted())")

    let columns = (0..<width).filter { x in
        stride(from: 0, to: height, by: 8).contains { pixels[$0 * width + x] < 250 }
    }
    let nearest = try #require(columns.min(by: { abs($0 - 500) < abs($1 - 500) }))
    #expect(abs(nearest - 500) <= 3, "the vertical should stand at x = 500; inked columns \(columns)")
}

@Test("A name the environment does not carry is written down, not swallowed")
func unknownNameIsReported() throws {
    // `paperWidth` is not a name the environment supplies. Falling back to
    // zero stays the behaviour — half a ruling beats a blank page — but the
    // fallback must say so, or a template that leans on such a name would be
    // mis-set without a trace.
    let template = try probeTemplate("""
    {
        "name": "UnknownNameProbe",
        "items": [
            {"type": "path", "data": ["M", 0, "paperWidth", "L", 100, "paperWidth"]}
        ]
    }
    """)

    let (context, _) = try probeCanvas(width: 200, height: 200)
    let problems = TemplateRenderer.drawReportingProblems(
        template,
        in: context,
        size: CGSize(width: 200, height: 200)
    )

    #expect(
        problems.messages.contains { $0.contains("paperWidth") },
        "the missing name must be named: \(problems.messages.sorted())"
    )
}

@Test("A path command we do not draw is written down, and its case is kept")
func undrawnPathCommandIsReported() throws {
    // `Q` is a command the renderer does not implement; `l` is a lineto
    // counted from the previous point. Upper-casing would turn that `l` into
    // an absolute `L` and draw a line to the wrong place without a word.
    // Neither is drawn, and both are named.
    let template = try probeTemplate("""
    {
        "name": "CommandProbe",
        "items": [
            {"type": "path", "data": ["M", 0, 0, "Q", 10, 10, 20, 20]},
            {"type": "path", "data": ["M", 0, 0, "l", 50, 50]}
        ]
    }
    """)

    let (context, _) = try probeCanvas(width: 200, height: 200)
    let problems = TemplateRenderer.drawReportingProblems(
        template,
        in: context,
        size: CGSize(width: 200, height: 200)
    )

    #expect(
        problems.messages.contains { $0.contains("\"Q\"") },
        "an unimplemented command must be named: \(problems.messages.sorted())"
    )
    #expect(
        problems.messages.contains { $0.contains("\"l\"") },
        "a relative command must stay lowercase and be named: \(problems.messages.sorted())"
    )
}

// `Int(_:)` traps on a value it cannot hold, and the repeat count of a group is
// exactly such a value read off a file: `JSONDecoder` hands `1e400` over as
// infinity, and an expression may come to anything at all. A template is data,
// and `TemplateProblems` is the promise that bad data is written down rather
// than allowed to take the process down — this is that promise for the counts.
@Test("A repeat count that is not a number, or is past counting, is still a count")
func repeatCountSurvivesWhatIntCannotHold() {
    #expect(TemplateRenderer.repeatCount(.infinity) == 1)
    #expect(TemplateRenderer.repeatCount(-.infinity) == 1)
    #expect(TemplateRenderer.repeatCount(.nan) == 1)
    #expect(TemplateRenderer.repeatCount(1e300) == TemplateRenderer.maximumRepeats)
    #expect(TemplateRenderer.repeatCount(Double(Int.max) * 4) == TemplateRenderer.maximumRepeats)
    #expect(TemplateRenderer.repeatCount(-5) == 1)
    #expect(TemplateRenderer.repeatCount(0) == 1)
    // What a sane number was always read as: truncated, the way `Int(_:)`
    // truncates, and never below one.
    #expect(TemplateRenderer.repeatCount(3.9) == 3)
    #expect(TemplateRenderer.repeatCount(12) == 12)
}

@Test("A template asking for more rows than can be counted is drawn, not crashed on")
func oversizedRepeatDrawsRatherThanTraps() throws {
    // An expression rather than a literal: `JSONDecoder` refuses a number a
    // double cannot hold, but an expression is evaluated here, and a product
    // like this one comes to 2 × 10²⁹ — well past what `Int(_:)` will take.
    let template = try probeTemplate("""
    {
        "name": "OversizedRowsProbe",
        "items": [
            {
                "type": "group",
                "boundingBox": {"x": 0, "y": 0, "width": 200, "height": 20},
                "repeat": {"rows": "templateHeight * 1000000000 * 1000000000 * 1000000000"},
                "children": [
                    {"type": "path", "data": ["M", 0, 10, "L", 200, 10]}
                ]
            }
        ]
    }
    """)

    let (context, pixels) = try probeCanvas(width: 200, height: 200)
    TemplateRenderer.drawReportingProblems(template, in: context, size: CGSize(width: 200, height: 200))

    // Ruled every 20 units down the page, as far as the page goes: ten rules,
    // each a row or two of pixels wide.
    let ruled = inkedRows(pixels, width: 200, height: 200)
    #expect(ruled.count >= 10 && ruled.count <= 30, "\(ruled.count) inked rows")
    #expect(ruled.contains { $0 >= 180 }, "the last rule reaches the foot of the page")
}

// MARK: - Every fixture draws

// A template can decode perfectly and evaluate to nothing at all, and a page
// carrying it would come out blank with no error anywhere.
@Test("Every fixture template puts something on the page", arguments: FixtureTemplates.all.keys.sorted())
func everyFixtureTemplateDraws(name: String) throws {
    let template = try #require(FixtureTemplates.store.template(named: name), "\(name) did not load")

    // The canvas the template was written against: the landscape ones run
    // their rules out to the long edge and would be cut in half on an upright
    // sheet — see `NotebookRenderer.canvas`.
    let size = template.isLandscape
        ? CGSize(width: PageRenderer.defaultPageSize.height, height: PageRenderer.defaultPageSize.width)
        : PageRenderer.defaultPageSize
    let width = Int(size.width), height = Int(size.height)
    let (context, pixels) = try probeCanvas(width: width, height: height)
    let problems = TemplateRenderer.drawReportingProblems(template, in: context, size: size)

    // Counted sparsely: what is being asked is "did anything land", and a
    // template's rules are spread across the sheet.
    let inked = stride(from: 0, to: width * height, by: 7).count { pixels[$0] < 250 }
    #expect(inked > 0, "\(name) drew nothing at \(width)×\(height)")
    #expect(
        problems.messages.isEmpty,
        "\(name): \(problems.messages.sorted().joined(separator: "; "))"
    )
}

@Test("A template's labels are black while its rules stay grey")
func templateTextIsDarkerThanTheRules() throws {
    // Rules take `Calibration.templateStroke`, #C0C0C0, which rasterises to
    // 192; labels are black.
    let template = try #require(FixtureTemplates.store.template(named: "Fixture Week"))

    let width = 2160
    let height = 1620
    let (context, pixels) = try probeCanvas(width: width, height: height)
    TemplateRenderer.draw(template, in: context, size: CGSize(width: width, height: height))

    var darkestLabel = 255
    var darkestRule = 255
    for row in 0..<height {
        for column in 0..<width {
            let value = Int(pixels[row * width + column])
            guard value < 250 else { continue }
            // The day names sit in the band above their baseline at 200;
            // everything below 400 on this template is ruling.
            if (160...205).contains(row) {
                darkestLabel = min(darkestLabel, value)
            } else if row > 400 {
                darkestRule = min(darkestRule, value)
            }
        }
    }

    #expect(darkestLabel < 40, "the labels should have a black core, darkest was \(darkestLabel)")
    #expect(darkestRule > 150, "the ruling should stay grey, darkest was \(darkestRule)")
    #expect(darkestLabel < darkestRule)
}

@Test("The ruled templates are measured off their own drawing")
func measuresTheRuling() throws {
    let store = FixtureTemplates.store
    let page = CGSize(width: 1404, height: 1872)
    let offered = store.ruledTemplates(pageSize: page)
    let names = Set(offered.map(\.name))

    // The lined pads and the grids, which are what a hand is written along.
    for name in ["Fixture Lines", "Fixture Margin Lines", "Fixture Grid", "Fixture Dots"] {
        #expect(names.contains(name), "\(name) is not offered as paper")
    }
    // Ruled as evenly as a pad and nothing anybody writes a letter on: one
    // is filed under Creative, another rules only the top of the page, the
    // rest are landscape or no ruling at all.
    for name in ["Fixture Sketch Guide", "Fixture Header Lines", "Fixture Week", "Fixture Columns"] {
        #expect(!names.contains(name), "\(name) is offered as paper")
    }

    let lines = try #require(offered.first { $0.name == "Fixture Lines" })
    #expect(lines.title == "Lines", "the reader is shown the template's own name")
    #expect(abs(lines.ruling.pitch - 80) < 0.2, "the pad rules every 80 units, not \(lines.ruling.pitch)")
    #expect(abs(lines.ruling.first - 160) < 1, "its first rule stands at 160, not \(lines.ruling.first)")
    #expect(lines.ruling.leftMargin == nil, "a plain pad draws no margin")

    let grid = try #require(offered.first { $0.name == "Fixture Grid" })
    #expect(abs(grid.ruling.pitch - 60) < 0.2)
    #expect(grid.ruling.leftMargin == nil, "a grid's verticals are no margin")

    let pad = try #require(offered.first { $0.name == "Fixture Margin Lines" })
    let margin = try #require(pad.ruling.leftMargin, "a margin pad draws one")
    #expect(abs(margin - 234) < 2, "its margin stands a sixth of the way in, not at \(margin)")

    // A template rules itself by the page it is drawn on: the same name on a
    // wider page answers with its own numbers.
    let wide = try #require(
        store.ruling(named: "Fixture Margin Lines", pageSize: CGSize(width: 1620, height: 2160))
    )
    #expect(wide.leftMargin != margin, "the margin moves with the page")
}

@Test("A template that rules nothing is no paper to write on")
func refusesAnUnruledTemplate() {
    let page = CGSize(width: 1404, height: 1872)
    #expect(FixtureTemplates.store.ruling(named: "Fixture Header Lines", pageSize: page) == nil)
    #expect(FixtureTemplates.store.ruling(named: "Fixture Columns", pageSize: page) == nil)
    #expect(FixtureTemplates.store.ruling(named: "no such template", pageSize: page) == nil)
}
