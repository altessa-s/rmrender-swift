// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines
import RMRender
import Testing

// The one half of the writer's proof that needs a picture. That a draft
// written and read back answers with the same text, styles, strokes and
// anchors is the parser's own repository to show; where an anchored image
// *lands* is this side of the wall, because it takes a font and a column
// width, and both belong to drawing.
@Suite("An anchored image's geometry")
struct AnchoredImageGeometryTests {
    private func sampleDraft() -> RMPageDraft {
        RMPageDraft(
            author: UUID(),
            sheet: RMPageDraft.Sheet(
                screenWidth: 1404,
                screenHeight: 1872,
                canvasWidth: 1404,
                canvasHeight: 1872
            ),
            column: RMPageDraft.Column(width: 936, setting: 1),
            paragraphs: [
                RMPageDraft.Paragraph("Heading", style: 2),
                RMPageDraft.Paragraph("Plain body"),
                RMPageDraft.Paragraph("Bold words", bold: true),
            ],
            strokes: [
                RMPageDraft.Stroke(tool: .fineliner2, color: .black, points: [
                    RMPageDraft.Point(x: 0, y: 100),
                    RMPageDraft.Point(x: 50, y: 100),
                    RMPageDraft.Point(x: 100, y: 100),
                ]),
            ],
            marks: [
                RMPageDraft.Mark(
                    anchor: .firstCharacter(paragraph: 1),
                    penOrigin: -464,
                    stroke: RMPageDraft.Stroke(tool: .fineliner2, color: .red, points: [
                        RMPageDraft.Point(x: 0, y: -10),
                        RMPageDraft.Point(x: 40, y: -10),
                    ])
                ),
            ]
        )
    }

    @Test("An anchored image rides its paragraph down when text grows above")
    func anchoredImageRidesItsParagraph() throws {
        func draft(paragraphs: [RMPageDraft.Paragraph], anchoredTo paragraph: Int) -> RMPageDraft {
            var draft = sampleDraft()
            draft.paragraphs = paragraphs
            draft.strokes = []
            draft.marks = []
            draft.images = [
                RMPageDraft.Image(
                    file: "0a418e1a-1111-4222-8333-444455556666.png",
                    key: Array(0 ..< 16),
                    x: 40,
                    y: 30,
                    width: 120,
                    height: 80,
                    anchor: .firstCharacter(paragraph: paragraph),
                    penOrigin: -464
                ),
            ]
            return draft
        }
        let short = try RMParser.parsePage(RMWriter.page(
            draft(paragraphs: [RMPageDraft.Paragraph("Target")], anchoredTo: 0)
        ))
        let tall = try RMParser.parsePage(RMWriter.page(draft(
            paragraphs: [RMPageDraft.Paragraph("Above"), RMPageDraft.Paragraph("Target")],
            anchoredTo: 1
        )))
        let placedShort = try #require(PageRenderer.placedImages(of: short).first)
        let placedTall = try #require(PageRenderer.placedImages(of: tall).first)
        // The pen's horizontal comes from `anchor_origin_x`; the vertical is
        // the anchored line's baseline, one line lower on the taller page.
        let shortX = try #require(placedShort.vertices.first?.x)
        #expect(abs(shortX - (-464 + 40)) < 0.01, "\(shortX)")
        let shortY = try #require(placedShort.vertices.first?.y)
        let tallY = try #require(placedTall.vertices.first?.y)
        #expect(tallY > shortY)
    }
}
