// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
@testable import RMRender

/// Page templates written for these tests: simple lines, grids, dots and a
/// planner, each small enough to reason about from its JSON. A host may
/// replace the bundled set with a `TemplateSource` of its own, and this is
/// the source the tests supply.
struct FixtureTemplates: TemplateSource {
    /// Every fixture by the name a page refers to it with.
    static let all: [String: String] = [
        // A rule every 80 units from 160 down, across the whole page.
        "Fixture Lines": """
        {
            "name": "Lines",
            "categories": ["Lines"],
            "orientation": "portrait",
            "constants": [{"pitch": 80}, {"top": 160}],
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": "top", "width": "templateWidth", "height": "pitch"},
                    "repeat": {"rows": "down"},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0]}]
                }
            ]
        }
        """,
        // The same rules, and one full-height margin a sixth of the way in.
        "Fixture Margin Lines": """
        {
            "name": "Margin lines",
            "categories": ["Lines"],
            "orientation": "portrait",
            "constants": [{"pitch": 80}, {"top": 160}, {"margin": "templateWidth / 6"}],
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": "top", "width": "templateWidth", "height": "pitch"},
                    "repeat": {"rows": "down"},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0]}]
                },
                {"type": "path", "data": ["M", "margin", 0, "L", "margin", "templateHeight"]}
            ]
        }
        """,
        // Square cells of 60 units, tiled over the page from (30, 30).
        "Fixture Grid": """
        {
            "name": "Grid",
            "categories": ["Grids"],
            "orientation": "portrait",
            "constants": [{"cell": 60}],
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 30, "y": 30, "width": "cell", "height": "cell"},
                    "repeat": {"rows": "down", "columns": "right"},
                    "children": [
                        {"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0, "M", 0, 0, "L", 0, "parentHeight"]}
                    ]
                }
            ]
        }
        """,
        // A black dot every 40 units.
        "Fixture Dots": """
        {
            "name": "Dots",
            "categories": ["Grids"],
            "orientation": "portrait",
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 20, "y": 20, "width": 40, "height": 40},
                    "repeat": {"rows": "down", "columns": "right"},
                    "children": [{"type": "path", "strokeWidth": 3, "data": ["M", 0, 0, "L", 1, 0]}]
                }
            ]
        }
        """,
        // Eight rules at the top of the page and nothing below: ruled, but not
        // over enough of the page to write along.
        "Fixture Header Lines": """
        {
            "name": "Header lines",
            "categories": ["Lines"],
            "orientation": "portrait",
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": 160, "width": "templateWidth", "height": 80},
                    "repeat": {"rows": 8},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0]}]
                }
            ]
        }
        """,
        // Ruled exactly like `Fixture Lines`, but filed where nobody writes.
        "Fixture Sketch Guide": """
        {
            "name": "Sketch guide",
            "categories": ["Creative"],
            "orientation": "portrait",
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": 160, "width": "templateWidth", "height": 80},
                    "repeat": {"rows": "down"},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0]}]
                }
            ]
        }
        """,
        // One vertical at the left edge of a 58.4-unit cell anchored half a
        // cell left of the sheet square's edge, repeated rightwards.
        "Fixture Columns": """
        {
            "name": "Columns",
            "categories": ["Creative"],
            "orientation": "portrait",
            "constants": [{"cell": 58.4}],
            "items": [
                {
                    "type": "group",
                    "boundingBox": {
                        "x": "paperOriginX - cell / 2", "y": 0,
                        "width": "cell", "height": "templateHeight"
                    },
                    "repeat": {"columns": "right"},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", 0, "parentHeight"]}]
                }
            ]
        }
        """,
        // A landscape week: seven grey columns, grey rows below, and a black
        // day name centred over each column by its own `textWidth`.
        "Fixture Week": """
        {
            "name": "Week",
            "categories": ["Planners"],
            "orientation": "landscape",
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": 120, "width": "templateWidth / 7", "height": "templateHeight - 120"},
                    "repeat": {"columns": 7},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", 0, "parentHeight"]}]
                },
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": 300, "width": "templateWidth", "height": 100},
                    "repeat": {"rows": "down"},
                    "children": [{"type": "path", "data": ["M", 0, 0, "L", "parentWidth", 0]}]
                },
                {"type": "text", "text": "Sunday", "fontSize": 36,
                 "position": {"x": "0.5 * templateWidth / 7 - textWidth / 2", "y": 200}},
                {"type": "text", "text": "Monday", "fontSize": 36,
                 "position": {"x": "1.5 * templateWidth / 7 - textWidth / 2", "y": 200}},
                {"type": "text", "text": "Tuesday", "fontSize": 36,
                 "position": {"x": "2.5 * templateWidth / 7 - textWidth / 2", "y": 200}},
                {"type": "text", "text": "Wednesday", "fontSize": 36,
                 "position": {"x": "3.5 * templateWidth / 7 - textWidth / 2", "y": 200}},
                {"type": "text", "text": "Thursday", "fontSize": 36,
                 "position": {"x": "4.5 * templateWidth / 7 - textWidth / 2", "y": 200}},
                {"type": "text", "text": "Friday", "fontSize": 36,
                 "position": {"x": "5.5 * templateWidth / 7 - textWidth / 2", "y": 200}},
                {"type": "text", "text": "Saturday", "fontSize": 36,
                 "position": {"x": "6.5 * templateWidth / 7 - textWidth / 2", "y": 200}}
            ]
        }
        """,
        // Landscape staves written in plain numbers out to x = 1743, which an
        // upright 1404-wide page cannot hold.
        "Fixture Wide Staves": """
        {
            "name": "Wide staves",
            "categories": ["Creative"],
            "orientation": "landscape",
            "items": [
                {
                    "type": "group",
                    "boundingBox": {"x": 0, "y": 200, "width": 1743, "height": 50},
                    "repeat": {"rows": 5},
                    "children": [{"type": "path", "data": ["M", 100, 0, "L", 1743, 0]}]
                }
            ]
        }
        """,
    ]

    func templateNames() -> [String] {
        Self.all.keys.sorted()
    }

    func templateData(named name: String) -> Data? {
        Self.all[name].map { Data($0.utf8) }
    }

    /// A store over the fixtures, for a test that parses or measures them
    /// without going through the renderer.
    static let store = TemplateStore(source: FixtureTemplates())

    /// Installs the fixtures as the renderer's source, once per process.
    /// Every test that draws a page carrying a template goes through this,
    /// so tests running side by side never install different sources.
    static let installed: Void = TemplateStore.install(FixtureTemplates())
}
