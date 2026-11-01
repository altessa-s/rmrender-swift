// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import CoreGraphics
import Foundation
import ImageIO
import RMLines
@testable import RMRender
import Testing

@Test("Present corrupt images fail exports; missing and unused images do not")
func corruptImagePolicy() throws {
    let page = RMPage(strokes: [], skippedBlocks: 0, images: [
        PageImage(file: "own.png", vertices: [
            .init(x: -10, y: 10, u: 0, v: 0), .init(x: 10, y: 10, u: 1, v: 0),
            .init(x: 10, y: 30, u: 1, v: 1), .init(x: -10, y: 30, u: 0, v: 1),
        ], strokesBefore: 0),
    ])
    let bad = ["own.png": Data("corrupt".utf8)]
    #expect(throws: RenderError.self) { try PageRenderer.pdf(pages: [page], assets: bad) }
    #expect(throws: RenderError.self) {
        try PageRenderer.image(page: page, pageSize: CGSize(width: 100, height: 100), assets: bad)
    }
    let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: output) }
    let sentinel = Data("previous output".utf8)
    try sentinel.write(to: output)
    #expect(throws: RenderError.self) { try PageRenderer.pdf(pages: [page], assets: bad, to: output) }
    #expect(try Data(contentsOf: output) == sentinel)
    try PageAssets.validate([:])
    try PageAssets.validate(bad, for: [])
    _ = try PageRenderer.image(page: page, pageSize: CGSize(width: 100, height: 100), assets: bad, inkOnly: true)
}

@Test("A generated valid PNG passes the shared attachment validation")
func validImagePolicy() throws {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    try PageAssets.validate(["own.png": data as Data])
}
