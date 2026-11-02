// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import CoreGraphics
import Foundation
import ImageIO
import RMLines
@testable import RMRender
import Testing

private let quadPage = RMPage(strokes: [], skippedBlocks: 0, images: [
    PageImage(file: "own.png", vertices: [
        .init(x: -10, y: 10, u: 0, v: 0), .init(x: 10, y: 10, u: 1, v: 0),
        .init(x: 10, y: 30, u: 1, v: 1), .init(x: -10, y: 30, u: 0, v: 1),
    ], strokesBefore: 0),
])

private func validPNG() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func pixels(_ image: CGImage) throws -> Data {
    try #require(image.dataProvider?.data) as Data
}

@Test("A corrupt image leaves the same hole a missing one does, and every export still succeeds")
func corruptImageLeavesAHole() throws {
    let bad = ["own.png": Data("corrupt".utf8)]
    let size = CGSize(width: 100, height: 100)
    let holed = try PageRenderer.image(page: quadPage, pageSize: size, assets: bad)
    let missing = try PageRenderer.image(page: quadPage, pageSize: size, assets: [:])
    let drawn = try PageRenderer.image(page: quadPage, pageSize: size, assets: ["own.png": try validPNG()])
    #expect(try pixels(holed) == pixels(missing), "a corrupt image is drawn as a hole")
    #expect(try pixels(drawn) != pixels(missing), "the fixture's image is visible when it decodes")

    #expect(try !PageRenderer.pdf(pages: [quadPage], assets: bad).isEmpty)
    let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: output) }
    try PageRenderer.pdf(pages: [quadPage], assets: bad, to: output)
    #expect(CGPDFDocument(output as CFURL)?.numberOfPages == 1)
}

@Test("Undecodable attachments are dropped and counted as holes; decodable ones are kept")
func undecodableAttachmentsAreCounted() throws {
    let good = try validPNG()
    let kept = PageAssets.decodable(["own.png": Data("corrupt".utf8), "other.png": good], channel: "test")
    #expect(kept == ["other.png": good])

    let other = RMPage(strokes: [], skippedBlocks: 0, images: [
        PageImage(file: "other.png", vertices: [], strokesBefore: 0),
    ])
    let holes = PageAssets.holes(in: [quadPage, other, quadPage], assets: kept)
    #expect(holes.pages == 2)
    #expect(holes.images == 1)
    let none = PageAssets.holes(in: [other], assets: kept)
    #expect(none.pages == 0 && none.images == 0)
}
