// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
@testable import RMRender
import Testing

// The templates the package carries: that every name a tablet page uses
// resolves, that each one draws, and that the ruled ones measure as they say.

/// Every template name a tablet page may carry that the bundled set answers
/// to. A page refers to its template by this name and nothing else, so a name
/// missing here is a page drawn without its background.
private let tabletNames = [
    "Isometric", "LS Checklist", "LS Checklist double", "LS Dayplanner", "LS Dots bottom", "LS Dots top",
    "LS Four storyboards", "LS Grid bottom", "LS Grid margin large", "LS Grid margin med", "LS Grid top",
    "LS Lines bottom", "LS Lines medium", "LS Lines small", "LS Lines top", "LS Margin medium",
    "LS Margin small", "LS One storyboard", "LS One storyboard 2", "LS Piano sheet large",
    "LS Piano sheet medium", "LS Piano sheet small", "LS Two storyboards", "LS Week", "LS Week US",
    "Notes", "P Bass tab", "P Checklist", "P Cornell", "P Day", "P Dots S", "P Dots S bottom", "P Dots S top",
    "P Dots large", "P Four storyboards", "P Grid bottom", "P Grid large", "P Grid margin large",
    "P Grid margin med", "P Grid medium", "P Grid small", "P Grid top", "P Guitar chords", "P Guitar tab",
    "P Lined bottom", "P Lined heading", "P Lined top", "P Lines large", "P Lines medium", "P Lines small",
    "P Margin large", "P Margin medium", "P Margin small", "P One storyboard", "P Piano sheet large",
    "P Piano sheet medium", "P Piano sheet small", "P Two storyboards", "P US College", "P US Legal",
    "P Week", "P Week 2", "P Week US", "Perspective1", "Perspective2",
]

/// The upright sheets of the two tablet generations the bundled set is drawn
/// for.
private let sheets = [CGSize(width: 1404, height: 1872), CGSize(width: 1620, height: 2160)]

/// Upright sheets under a thousand units wide, where the templates switch to
/// their compact layouts: the small tablet's 954 × 1696, and a phone-sized
/// 720 × 1280. The renderer takes a page's canvas from what the page declares,
/// so a page written on either is drawn on it.
private let compactSheets = [CGSize(width: 954, height: 1696), CGSize(width: 720, height: 1280)]

/// Templates whose ruling is a pattern tiled past the edges of the sheet on
/// purpose — squares, dots, the isometric lattice — and is cut by the page
/// rather than laid out within it.
private func isTiled(_ template: Template, named name: String) -> Bool {
    template.categories?.contains("Grids") == true || name == "Isometric"
}

private let bundled = TemplateStore(source: BundledTemplates())

@Test("The bundled set answers to every name a tablet page uses, and to no other")
func bundledSetCoversTheTabletNames() {
    #expect(tabletNames.count == 65)
    #expect(BundledTemplates().templateNames() == tabletNames.sorted())
    for name in tabletNames {
        #expect(bundled.template(named: name) != nil, "\(name) does not resolve")
    }
}

@Test("The renderer draws from the bundled set until the host installs another source")
func sharedStoreDefaultsToTheBundledSet() {
    #expect(TemplateStore.defaultSource is BundledTemplates)
}

@Test("A template's orientation follows its name")
func bundledOrientationFollowsTheName() throws {
    for name in tabletNames {
        let template = try #require(bundled.template(named: name))
        #expect(template.isLandscape == name.hasPrefix("LS "), "\(name) is \(template.orientation ?? "unset")")
    }
}

@Test("No bundled file names an author or the tablet's maker")
func bundledTemplatesAreOurs() throws {
    let source = BundledTemplates()
    for name in tabletNames {
        let data = try #require(source.templateData(named: name))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["author"] == nil, "\(name) names an author")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("remarkable"), "\(name) names the tablet's maker")
    }
}

@Test(
    "Every bundled template draws, cleanly and within the sheet, on tablet and compact sheets",
    arguments: tabletNames
)
func everyBundledTemplateDraws(name: String) throws {
    let template = try #require(bundled.template(named: name), "\(name) did not load")
    for sheet in sheets + compactSheets {
        // Drawn on the canvas it was written for: landscape on the turned sheet.
        let size = template.isLandscape ? CGSize(width: sheet.height, height: sheet.width) : sheet
        let width = Int(size.width), height = Int(size.height)

        // A margin of bitmap all round the sheet, so that anything drawn past
        // its edges lands somewhere it can be seen.
        let pad = 40
        let fullWidth = width + 2 * pad, fullHeight = height + 2 * pad
        let (context, pixels) = try probeCanvas(width: fullWidth, height: fullHeight)
        context.translateBy(x: CGFloat(pad), y: CGFloat(pad))
        let problems = TemplateRenderer.drawReportingProblems(template, in: context, size: size)

        let at = "\(name) at \(width)×\(height)"
        #expect(problems.messages.isEmpty, "\(at): \(problems.messages.sorted().joined(separator: "; "))")

        func inked(columns: Range<Int>) -> Int {
            var count = 0
            for row in pad..<(pad + height) {
                for column in columns where pixels[row * fullWidth + column] < 250 {
                    count += 1
                }
            }
            return count
        }
        let inside = inked(columns: pad..<(pad + width))
        #expect(inside > 100, "\(at) drew next to nothing: \(inside)")

        // A square cap reaches half a line width past a rule's end, so a
        // couple of pixels of slack either side.
        let slack = 2
        let pastRight = inked(columns: (pad + width + slack)..<fullWidth)
        let pastLeft = inked(columns: 0..<(pad - slack))
        if isTiled(template, named: name) {
            // Cut by the page: it has to carry on to the right-hand edge, not
            // stop short of it — ink within one cell of the edge, and the
            // widest cell in the set is 104 units.
            #expect(inked(columns: (pad + width - 110)..<(pad + width)) > 0, "\(at) stops short of the right edge")
        } else {
            #expect(pastRight == 0, "\(at) runs past the right edge: \(pastRight) pixels")
            #expect(pastLeft == 0, "\(at) runs past the left edge: \(pastLeft) pixels")
        }
    }
}

/// A template's constants as the renderer works them out on a sheet: in
/// order, each one able to use the ones before it.
private func constants(of template: Template, on size: CGSize) throws -> [String: Double] {
    var environment: [String: Double] = [
        "templateWidth": size.width,
        "templateHeight": size.height,
        "paperOriginX": (size.width - size.height) / 2,
        "paperOriginY": 0,
    ]
    for pair in template.constants ?? [] {
        for (name, value) in pair {
            environment[name] = try value.resolved(in: environment)
        }
    }
    return environment
}

/// The upright pads and grids a hand is written along. The rest of the set is
/// either filed elsewhere, ruled over half its page or not evenly, or
/// landscape — and `TemplateScan` leaves those out by measurement.
private let ruledNames: Set<String> = [
    "P Lines small", "P Lines medium", "P Lines large",
    "P Margin small", "P Margin medium", "P Margin large",
    "P US College", "P US Legal",
    "P Grid small", "P Grid medium", "P Grid large", "P Grid margin med", "P Grid margin large",
    "P Dots S", "P Dots large",
]

@Test("The bundled ruled templates measure at the spacing they declare", arguments: sheets)
func bundledRulingsMatchTheirDeclaredSpacing(sheet: CGSize) throws {
    let offered = bundled.ruledTemplates(pageSize: sheet)
    #expect(Set(offered.map(\.name)) == ruledNames)

    for ruled in offered {
        let template = try #require(bundled.template(named: ruled.name))
        let declared = try constants(of: template, on: sheet)
        let pitch = try #require(declared["pitch"], "\(ruled.name) declares no pitch")
        #expect(abs(ruled.ruling.pitch - pitch) < 0.3, "\(ruled.name): pitch \(ruled.ruling.pitch), declared \(pitch)")

        // The first rule found is the declared first one, or one a whole pitch
        // further down where that one is at the very top of the sheet.
        let top = try #require(declared["top"], "\(ruled.name) declares no top")
        let phase = (ruled.ruling.first - top).truncatingRemainder(dividingBy: pitch)
        let off = min(abs(phase), pitch - abs(phase))
        #expect(off < 1.5, "\(ruled.name): first rule at \(ruled.ruling.first), declared from \(top)")

        if let margin = declared["margin"] {
            let found = try #require(ruled.ruling.leftMargin, "\(ruled.name) draws a margin")
            #expect(abs(found - margin) < 2, "\(ruled.name): margin at \(found), declared at \(margin)")
        } else {
            #expect(ruled.ruling.leftMargin == nil, "\(ruled.name) draws no margin")
        }
    }
}

@Test("Layered sources answer from the first layer that has the name")
func layeredSourcesPreferTheFirstLayer() throws {
    struct Override: TemplateSource {
        static let json = """
        {"name": "Override", "orientation": "portrait", "categories": ["Lines"], "items": []}
        """
        func templateNames() -> [String] { ["P Lines medium", "Host Only"] }
        func templateData(named name: String) -> Data? {
            templateNames().contains(name) ? Data(Self.json.utf8) : nil
        }
    }

    let layered = LayeredTemplates([Override(), BundledTemplates()])
    let store = TemplateStore(source: layered)
    #expect(store.template(named: "P Lines medium")?.name == "Override", "the host's own wins")
    #expect(store.template(named: "Host Only")?.name == "Override")
    #expect(store.template(named: "P Grid small")?.name == bundled.template(named: "P Grid small")?.name)
    #expect(store.template(named: "no such template") == nil)

    let names = store.availableNames()
    #expect(names.count == tabletNames.count + 1, "a name two layers share is listed once")
    #expect(names.contains("Host Only"))
}
