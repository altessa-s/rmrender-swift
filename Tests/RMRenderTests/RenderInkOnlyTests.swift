// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines
import RMRender
import Testing

// A reader that takes the typed text as text must not see it drawn as
// well: `inkOnly` leaves the text out and keeps the strokes.

@Test("Ink only leaves the typed text out and keeps the strokes")
func inkOnlyDrawsStrokesAlone() throws {
    let stroke = Stroke(
        tool: .ballpoint1,
        color: .black,
        thicknessScale: 1,
        points: (0..<40).map { index in
            StrokePoint(x: 100 + Float(index) * 4, y: 900, width: 10, pressure: 1)
        }
    )
    let page = RMPage(
        strokes: [stroke],
        skippedBlocks: 0,
        text: TextBlock(
            originX: -576, originY: 200, lines: ["The typed line that must not be drawn"], columnWidth: 1152
        )
    )
    let size = CGSize(width: 1404, height: 1872)

    let whole = try PageRenderer.image(page: page, pageSize: size, scale: 0.5)
    let inkOnly = try PageRenderer.image(page: page, pageSize: size, scale: 0.5, inkOnly: true)
    let strokesAlone = try PageRenderer.image(
        page: RMPage(strokes: [stroke], skippedBlocks: 0), pageSize: size, scale: 0.5
    )

    #expect(darkPixels(inkOnly) < darkPixels(whole), "the text was drawn on the whole page and not on the ink")
    #expect(darkPixels(inkOnly) == darkPixels(strokesAlone), "ink only is the strokes, no more and no less")
    #expect(darkPixels(inkOnly) > 0, "the stroke itself is still there")
}

private func darkPixels(_ image: CGImage) -> Int {
    guard let data = image.dataProvider?.data as Data? else { return 0 }
    let bytesPerPixel = image.bitsPerPixel / 8
    var count = 0
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset + 2 < bytes.count {
            if bytes[offset] < 128, bytes[offset + 1] < 128, bytes[offset + 2] < 128 { count += 1 }
            offset += bytesPerPixel
        }
    }
    return count
}
