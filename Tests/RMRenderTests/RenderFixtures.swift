// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines
@testable import RMRender
import Testing

// Shared page builders for the render suite.
//
// The fixtures are assembled here: real library pages are the user's
// private data and have no place in the repository. The tests that
// draw them live next door, one file per family, so a calibration
// of text does not drag the pens and the templates with it.

struct FixtureWriter {
    private(set) var bytes: [UInt8] = []

    mutating func append(_ byte: UInt8) { bytes.append(byte) }

    mutating func append(uint16 value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8(value >> 8))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func append(float value: Float) {
        append(uint32: value.bitPattern)
    }

    mutating func append(double value: Double) {
        let pattern = value.bitPattern
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8((pattern >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func append(varuint value: UInt64) {
        var rest = value
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while rest != 0
    }

    mutating func appendTag(index: Int, type: UInt8) {
        append(varuint: UInt64(index) << 4 | UInt64(type))
    }

    /// A CRDT identifier: a byte plus a varuint.
    mutating func appendID(index: Int) {
        appendTag(index: index, type: 0xF)
        append(1)
        append(varuint: 1)
    }

    mutating func append(contentsOf other: [UInt8]) {
        bytes.append(contentsOf: other)
    }
}

/// The service blocks every page opens with — authors, migration, counters
/// (the bytes `09 00 0a 0d …`).
///
/// Every fixture below carries them, because every page the tablet writes
/// does. Without them a fixture is a shape of file that exists nowhere, and a
/// counter of losses read against that shape can claim three blocks lost on
/// a page that has lost nothing while the test calls it fine.
func serviceBlocks() -> [UInt8] {
    func block(type: UInt8, version: UInt8, payload: [UInt8]) -> [UInt8] {
        var writer = FixtureWriter()
        writer.append(uint32: UInt32(payload.count))
        writer.append(0)                                      // reserved zero
        writer.append(version)                                // min_version
        writer.append(version)                                // current_version
        writer.append(type)
        writer.append(contentsOf: payload)
        return writer.bytes
    }

    // 0x09 — the author table: a count, then a subblock per author holding the
    // UUID as bytes_le and the author's own number.
    var authors = FixtureWriter()
    authors.append(varuint: 1)
    var author = FixtureWriter()
    author.append(varuint: 16)
    author.append(contentsOf: Array(repeating: 0xAB, count: 16))
    author.append(uint16: 1)
    authors.appendBlock(index: 0, author.bytes)

    // 0x00 — the migration record: seven bytes. `is_device` says who made the
    // page; 1 is the tablet itself.
    var migration = FixtureWriter()
    migration.appendID(index: 1, (author: 1, counter: 1))
    migration.appendTag(index: 2, type: 0x1)
    migration.append(1)                                       // is_device
    migration.appendTag(index: 3, type: 0x1)
    migration.append(0)

    // 0x0A — the page counters: loads, merges, characters, paragraphs, folio.
    var counters = FixtureWriter()
    for (index, value) in [1, 0, 0, 0, 0].enumerated() {
        counters.appendTag(index: index + 1, type: 0x4)
        counters.append(uint32: UInt32(value))
    }

    return block(type: 0x09, version: 3, payload: authors.bytes)
        + block(type: 0x00, version: 1, payload: migration.bytes)
        + block(type: 0x0A, version: 1, payload: counters.bytes)
}

/// One rectangle of a highlight, in the order the block writes them.
struct HighlightRect {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// A page carrying one highlight block (`0x03`): the marker over the text of
/// an imported PDF.
///
/// `declaredCount` writes a number of rectangles other than the number that
/// follows — which is what a corrupted blob looks like from the inside.
func makeHighlightPage(
    rectangles: [HighlightRect] = [
        HighlightRect(x: 10, y: 20, width: 100, height: 30)
    ],
    declaredCount: UInt64? = nil,
    text: String? = nil
) -> Data {
    var boxes = FixtureWriter()
    boxes.append(varuint: declaredCount ?? UInt64(rectangles.count))
    for rectangle in rectangles {
        boxes.append(double: rectangle.x)
        boxes.append(double: rectangle.y)
        boxes.append(double: rectangle.width)
        boxes.append(double: rectangle.height)
    }

    var value = FixtureWriter()
    value.append(0x05)                                    // value type
    value.appendTag(index: 4, type: 0x4)
    value.append(uint32: UInt32(PenColor.yellow.rawValue))
    if let text {
        // The words the tablet copied out of the text layer, in the shape
        // the typed text uses: a count, an encoding marker, the bytes.
        var words = FixtureWriter()
        let bytes = Array(text.utf8)
        words.append(varuint: UInt64(bytes.count))
        words.append(1)                                   // encoding marker
        words.append(contentsOf: bytes)
        value.appendBlock(index: 5, words.bytes)
    }
    value.appendBlock(index: 6, boxes.bytes)

    var payload = FixtureWriter()
    payload.appendID(index: 1, (author: 1, counter: 1))   // parent
    payload.appendID(index: 2, (author: 1, counter: 2))   // item
    payload.appendID(index: 3, (author: 0, counter: 0))   // left
    payload.appendID(index: 4, (author: 0, counter: 0))   // right
    payload.appendTag(index: 5, type: 0x4)
    payload.append(uint32: 0)                             // deleted length
    payload.appendBlock(index: 6, value.bytes)

    var file = FixtureWriter()
    file.append(contentsOf: Array(RMParser.header.utf8))
    file.append(contentsOf: serviceBlocks())
    file.append(uint32: UInt32(payload.bytes.count))
    file.append(0)                                        // reserved zero
    file.append(2)                                        // min_version
    file.append(2)                                        // current_version
    file.append(0x03)                                     // SceneGlyphItem
    file.append(contentsOf: payload.bytes)
    return Data(file.bytes)
}

/// One sample of a stroke as the file carries it.
///
/// The tablet stores no curves at all: it samples the pen fast enough that the
/// polyline *is* the curve, so a fixture of a curve is a fixture of its
/// samples. Speed, direction and pressure travel with every one of them, and
/// the two point formats spell them differently — see `makePage`.
struct StrokeSample {
    var x: Float
    var y: Float
    /// The raw width, the number `StrokePoint.width` hands back untouched.
    /// Kept a multiple of four so that version one, which stores a quarter of
    /// it as a float32, round-trips exactly.
    var width: UInt16 = 8
    var speed: UInt16 = 100
    var direction: UInt8 = 0
    var pressure: UInt8 = 200
}

/// A page with a single pen stroke.
///
/// `pointVersion` is the block's own version byte, and it decides how the
/// points are written: version one spells all six fields as float32 — with the
/// width in quarters and the pressure as a fraction — while version two packs
/// speed and width into uint16 and direction and pressure into single bytes
/// (`RMParser.parsePoint`).
func makePage(
    tool: UInt32 = UInt32(PenTool.fineliner1.rawValue),
    color: UInt32 = UInt32(PenColor.blue.rawValue),
    thickness: Double = 2,
    points: [StrokeSample] = [StrokeSample(x: 0, y: 0), StrokeSample(x: 10, y: 20)],
    pointVersion: UInt8 = 2,
    blockType: UInt8 = 0x05,
    argb: UInt32? = nil,
    // An erased item keeps its block and loses its value. That is how the
    // tablet rubs something out.
    erased: Bool = false,
    // The scene identifiers: which node the stroke belongs to, its own id
    // and its place in the parent's chain.
    parent: (author: UInt8, counter: UInt64) = (1, 1),
    item: (author: UInt8, counter: UInt64) = (1, 1),
    left: (author: UInt8, counter: UInt64) = (1, 1),
    // On by default: a page without the service quartet is a page no tablet
    // writes. Off only where a test needs the bytes bare.
    service: Bool = true,
    // Straight into the points, replacing what the samples above would occupy.
    // A declaration is not a promise, and this is how a file lies about one.
    pointsLength: UInt32? = nil,
    // The same lie one level up: the length of the value the points live in.
    valueLength: UInt32? = nil
) -> Data {
    var value = FixtureWriter()
    value.append(0x03)                                    // value type: stroke
    value.appendTag(index: 1, type: 0x4)
    value.append(uint32: tool)
    value.appendTag(index: 2, type: 0x4)
    value.append(uint32: color)
    value.appendTag(index: 3, type: 0x8)
    value.append(double: thickness)
    value.appendTag(index: 4, type: 0x4)
    value.append(float: 0)

    var pointBytes = FixtureWriter()
    for point in points {
        pointBytes.append(float: point.x)
        pointBytes.append(float: point.y)
        if pointVersion == 1 {
            pointBytes.append(float: Float(point.speed))
            pointBytes.append(float: Float(point.direction))
            // The parser multiplies these back by 4 and by 255, so the file
            // carries the quarter and the fraction.
            pointBytes.append(float: Float(point.width) / 4)
            pointBytes.append(float: Float(point.pressure) / 255)
        } else {
            pointBytes.append(uint16: point.speed)
            pointBytes.append(uint16: point.width)
            pointBytes.append(point.direction)
            pointBytes.append(point.pressure)
        }
    }
    value.appendTag(index: 5, type: 0xC)
    value.append(uint32: pointsLength ?? UInt32(pointBytes.bytes.count))
    value.append(contentsOf: pointBytes.bytes)

    // The tail newer files carry: a timestamp and an explicit colour.
    if let argb {
        value.appendID(index: 6)
        value.appendTag(index: 8, type: 0x4)
        value.append(uint32: argb)
    }

    var payload = FixtureWriter()
    payload.appendID(index: 1, parent)
    payload.appendID(index: 2, item)
    payload.appendID(index: 3, left)
    payload.appendID(index: 4, (author: 0, counter: 0))   // right
    payload.appendTag(index: 5, type: 0x4)
    payload.append(uint32: erased ? 1 : 0)                // deleted length
    if !erased {
        payload.appendTag(index: 6, type: 0xC)
        payload.append(uint32: valueLength ?? UInt32(value.bytes.count))
        payload.append(contentsOf: value.bytes)
    }

    var file = FixtureWriter()
    file.append(contentsOf: Array(RMParser.header.utf8))
    if service { file.append(contentsOf: serviceBlocks()) }
    file.append(uint32: UInt32(payload.bytes.count))
    file.append(0)                                        // unknown field
    file.append(pointVersion)                             // min_version
    file.append(pointVersion)                             // current_version
    file.append(blockType)
    file.append(contentsOf: payload.bytes)

    return Data(file.bytes)
}

/// A scene tree node — the block a layer's own properties live in. `visible`
/// is the flag the tablet writes when the user hides the layer; the stroke
/// `makePage` builds names this very node as its parent.
func layerNode(visible: Bool) -> [UInt8] {
    var flag = FixtureWriter()
    flag.appendID(index: 1)                               // the last write
    flag.appendTag(index: 2, type: 0x1)
    flag.append(visible ? 1 : 0)

    var payload = FixtureWriter()
    payload.appendID(index: 1)                            // the node itself
    payload.appendTag(index: 3, type: 0xC)
    payload.append(uint32: UInt32(flag.bytes.count))
    payload.append(contentsOf: flag.bytes)

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)                                       // unknown field
    block.append(2)                                       // min_version
    block.append(2)                                       // current_version
    block.append(0x02)                                    // a scene tree node
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

/// The same page, with a layer node in front of the stroke that belongs to it.
func makePage(layerVisible: Bool) -> Data {
    let page = makePage()
    let header = RMParser.header.utf8.count
    return Data(
        Array(page.prefix(header)) + layerNode(visible: layerVisible) + Array(page.dropFirst(header))
    )
}

/// One record of the text list: either characters or a mark that switches a
/// face on or off. `left` is what puts it in its place — the order of the text
/// is the chain of these links, not the order the records lie in.
struct TextRecord {
    var id: (author: UInt8, counter: UInt64)
    var left: (author: UInt8, counter: UInt64)
    var text: String = ""
    /// 1 bold on, 2 bold off, 3 italic on, 4 italic off.
    var faceMark: UInt32?
    /// The neighbour on the right. Two records sharing a `left` are ordinary
    /// in a CRDT, and this is what tells which of them comes first.
    var right: (author: UInt8, counter: UInt64) = (0, 0)
    /// How many characters this record deletes. A deletion keeps its place in
    /// the sequence, and the next record's `left` counts past it.
    var deleted: UInt32 = 0
}

/// One record of the paragraph style list. The key is the character that ends
/// the paragraph *before* this one — a newline — or (0, 0) for the first.
struct StyleRecord {
    var key: (author: UInt8, counter: UInt64)
    var style: UInt8
    /// The fields past the first. Present or absent is the whole difference
    /// between an emphasised paragraph and a subheading.
    var furtherFields: Bool = false
    /// `tag 2` and `tag 3` spelled out, for the records where their values
    /// matter rather than their mere presence: a nested list item packs its
    /// family and its depth into `tag 3` (`ParagraphFormat.level`). Setting
    /// either one implies the record goes on.
    var second: UInt8?
    var third: UInt32?
}

extension FixtureWriter {
    mutating func appendID(index: Int, _ value: (author: UInt8, counter: UInt64)) {
        appendTag(index: index, type: 0xF)
        append(value.author)
        append(varuint: value.counter)
    }

    mutating func appendBareID(_ value: (author: UInt8, counter: UInt64)) {
        append(value.author)
        append(varuint: value.counter)
    }

    /// A tagged subblock: the tag, the length of what follows, and the bytes.
    mutating func appendBlock(index: Int, _ body: [UInt8]) {
        appendTag(index: index, type: 0xC)
        append(uint32: UInt32(body.count))
        append(contentsOf: body)
    }
}

/// A page of typed text: the `0x07` block, assembled the way the tablet writes
/// it — both lists inside one subblock, the origin, and the column width as a
/// float32 under a `byte4` tag.
func makeTextPage(
    records: [TextRecord],
    styles: [StyleRecord] = [],
    origin: (x: Double, y: Double) = (-576, 200),
    columnWidth: Float? = nil
) -> Data {
    var items = FixtureWriter()
    items.append(varuint: UInt64(records.count))
    for record in records {
        var body = FixtureWriter()
        body.appendID(index: 2, record.id)
        body.appendID(index: 3, record.left)
        body.appendID(index: 4, record.right)
        body.appendTag(index: 5, type: 0x4)
        body.append(uint32: record.deleted)

        var value = FixtureWriter()
        // UTF-8 bytes, not graphemes: the parser reads the field as a byte
        // length, and on ASCII the difference is invisible.
        value.append(varuint: UInt64(record.text.utf8.count))
        value.append(1)                                        // encoding marker
        value.append(contentsOf: Array(record.text.utf8))
        if let mark = record.faceMark {
            value.appendTag(index: 2, type: 0x4)
            value.append(uint32: mark)
        }
        body.appendBlock(index: 6, value.bytes)

        items.appendBlock(index: 0, body.bytes)
    }
    var itemList = FixtureWriter()
    itemList.appendBlock(index: 1, items.bytes)
    var itemContainer = FixtureWriter()
    itemContainer.appendBlock(index: 1, itemList.bytes)

    var styleRows = FixtureWriter()
    styleRows.append(varuint: UInt64(styles.count))
    for style in styles {
        styleRows.appendBareID(style.key)
        styleRows.appendID(index: 1, (author: 0, counter: 0))   // the last write
        var value = FixtureWriter()
        value.appendTag(index: 1, type: 0x1)
        value.append(style.style)
        if let second = style.second ?? (style.furtherFields ? 2 : nil) {
            value.appendTag(index: 2, type: 0x1)
            value.append(second)
        }
        if let third = style.third ?? (style.furtherFields ? 3 : nil) {
            value.appendTag(index: 3, type: 0x4)
            value.append(uint32: third)
        }
        styleRows.appendBlock(index: 2, value.bytes)
    }
    var styleList = FixtureWriter()
    styleList.appendBlock(index: 1, styleRows.bytes)

    var both = FixtureWriter()
    both.append(contentsOf: itemContainer.bytes)
    both.appendBlock(index: 2, styleList.bytes)

    var position = FixtureWriter()
    position.append(double: origin.x)
    position.append(double: origin.y)

    var payload = FixtureWriter()
    payload.appendID(index: 1, (author: 1, counter: 1))
    payload.appendBlock(index: 2, both.bytes)
    payload.appendBlock(index: 3, position.bytes)
    if let columnWidth {
        payload.appendTag(index: 4, type: 0x4)
        payload.append(float: columnWidth)
    }

    var file = FixtureWriter()
    file.append(contentsOf: Array(RMParser.header.utf8))
    file.append(contentsOf: serviceBlocks())
    file.append(uint32: UInt32(payload.bytes.count))
    file.append(0)                                             // unknown field
    file.append(2)                                             // min_version
    file.append(2)                                             // current_version
    file.append(0x07)                                          // RootText
    file.append(contentsOf: payload.bytes)
    return Data(file.bytes)
}

/// A tree node whose anchor points into the text: tag 7 names the character,
/// tag 10 carries the ready horizontal. The node's identifier is (1, 1) — the
/// same one `makePage`'s stroke names as its parent.
func anchorNode(
    character: (author: UInt8, counter: UInt64),
    originX: Float?,
    wrapped: Bool = false,
    node: (author: UInt8, counter: UInt64) = (1, 1)
) -> [UInt8] {
    var anchor = FixtureWriter()
    anchor.appendID(index: 1, (author: 0, counter: 0))    // the node's own id
    anchor.appendID(index: 2, character)                  // the character

    var payload = FixtureWriter()
    payload.appendID(index: 1, node)                      // the node itself
    payload.appendBlock(index: 7, anchor.bytes)
    if let originX {
        if wrapped {
            // The last-write-wins spelling `rmscene` reads: a timestamp,
            // then the value.
            var lww = FixtureWriter()
            lww.appendID(index: 1, (author: 0, counter: 0))
            lww.appendTag(index: 2, type: 0x4)
            lww.append(float: originX)
            payload.appendBlock(index: 10, lww.bytes)
        } else {
            payload.appendTag(index: 10, type: 0x4)
            payload.append(float: originX)
        }
    }

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)                                       // unknown field
    block.append(2)                                       // min_version
    block.append(2)                                       // current_version
    block.append(0x02)                                    // a scene tree node
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

/// A page of typed text with one anchored stroke: the text block, the tree
/// node carrying the anchor, and the stroke whose parent that node is.
func makeAnchoredPage(originX: Float?, wrapped: Bool = false) -> Data {
    let text = makeTextPage(records: [TextRecord(id: (1, 10), left: (0, 0), text: "one two")])
    let stroke = makePage()
    let header = RMParser.header.utf8.count
    return Data(
        Array(text.prefix(header))
            + anchorNode(character: (1, 12), originX: originX, wrapped: wrapped)
            + Array(text.dropFirst(header))
            + Array(stroke.dropFirst(header))
    )
}

/// The scene info block (`0x0D`): the visibility flags as last-write-wins
/// records and the sheet size as two `uint32`s.
///
/// A scene declaring an upright canvas must not overrule a document that
/// says it lies on its side — the sheet tests check that pairing.
func sceneInfoBlock(
    backgroundVisible: Bool?,
    rootDocumentVisible: Bool?,
    size: (width: UInt32, height: UInt32)? = (1620, 2160),
    // The same sheet unrounded — two `float64` under tag 7, and the one the
    // format calls authoritative. A page may carry either, or both.
    canvas: (width: Double, height: Double)? = nil
) -> [UInt8] {
    var payload = FixtureWriter()
    func lww(index: Int, flag: Bool) {
        var record = FixtureWriter()
        record.appendID(index: 1, (author: 0, counter: 0))    // the last write
        record.appendTag(index: 2, type: 0x1)
        record.append(flag ? 1 : 0)
        payload.appendBlock(index: index, record.bytes)
    }
    if let backgroundVisible { lww(index: 2, flag: backgroundVisible) }
    if let rootDocumentVisible { lww(index: 3, flag: rootDocumentVisible) }
    if let size {
        var value = FixtureWriter()
        value.append(uint32: size.width)
        value.append(uint32: size.height)
        payload.appendBlock(index: 5, value.bytes)
    }
    if let canvas {
        var value = FixtureWriter()
        value.append(double: canvas.width)
        value.append(double: canvas.height)
        payload.appendBlock(index: 7, value.bytes)
    }

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)                                       // unknown field
    block.append(0)                                       // min_version
    block.append(1)                                       // current_version
    block.append(0x0D)                                    // scene info
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

/// A block of typed text in the shape a live page has it: the column 1152
/// units wide, the same as `typedPage` below.
func typedText(
    _ lines: [String],
    formats: [Int: ParagraphFormat] = [:]
) -> TextBlock {
    TextBlock(originX: -576, originY: 300, lines: lines, formats: formats, columnWidth: 1152)
}

/// A stroke of one point at the origin: what matters here is where it ends up,
/// not what it looks like.
func anchoredStroke(to paragraph: Int, offset: Int = 0, originX: Double? = nil) -> Stroke {
    Stroke(
        tool: .ballpoint2,
        color: .black,
        thicknessScale: 2,
        points: [StrokePoint(x: 0, y: 0, width: 8, pressure: 100)],
        anchor: TextAnchor(paragraph: paragraph, offset: offset, originX: originX)
    )
}

func placedPoint(_ stroke: Stroke, on text: TextBlock) throws -> StrokePoint {
    let geometry = TextGeometry(text, pageSize: PageRenderer.defaultPageSize)
    return try #require(geometry.placing([stroke]).first?.points.first)
}

/// A page of typed text and nothing else — a shape that must not come out
/// blank.
func typedPage(
    lines: [String],
    styles: [Int: ParagraphStyle] = [:],
    formats: [Int: ParagraphFormat] = [:],
    faces: [Int: [FaceRun]] = [:],
    columnWidth: Double? = nil
) -> RMPage {
    RMPage(
        strokes: [],
        skippedBlocks: 0,
        text: TextBlock(
            originX: -576,
            originY: 300,
            lines: lines,
            formats: formats.merging(
                styles.mapValues { ParagraphFormat(style: $0) },
                uniquingKeysWith: { given, _ in given }
            ),
            faces: faces,
            columnWidth: columnWidth
        )
    )
}

/// The first page drawn onto white, one byte a pixel: dark or not.
///
/// Drawn by CoreGraphics rather than read out of the PDF's operators — what
/// matters to the user is what lands on the paper, not what the file says.
func raster(_ pdf: Data) throws -> (width: Int, height: Int, dark: [Bool]) {
    let provider = try #require(CGDataProvider(data: pdf as CFData))
    let document = try #require(CGPDFDocument(provider))
    let page = try #require(document.page(at: 1))
    let box = page.getBoxRect(.mediaBox)
    let width = Int(box.width), height = Int(box.height)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.drawPDFPage(page)
    let buffer = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    // Row nought is the top of the page, so that a row number reads the way
    // one looks at paper. A bitmap context counts its coordinates from the
    // bottom left but lays its rows out from the top, so this is a plain copy —
    // flipping it here is what made a row number mean the opposite of what it
    // said.
    var dark = [Bool](repeating: false, count: width * height)
    for index in 0..<(width * height) {
        dark[index] = Int(buffer[index * 4]) < 128
    }
    return (width, height, dark)
}

/// The distance from the first mark on the page to the last.
func inkHeight(in pdf: Data) throws -> Int {
    let image = try raster(pdf)
    var first: Int?
    var last = 0
    for y in 0..<image.height {
        for x in 0..<image.width where image.dark[y * image.width + x] {
            if first == nil { first = y }
            last = y
            break
        }
    }
    return last - (first ?? 0)
}

/// The last row of the page carrying ink, counted from the top.
func lowestInk(in pdf: Data) throws -> Int {
    let image = try raster(pdf)
    let rows = (0..<image.height).reversed()
    for row in rows where (0..<image.width).contains(where: { image.dark[row * image.width + $0] }) {
        return row
    }
    return 0
}

/// The dark pixels of the first page — the test's way of asking "is anything
/// there at all".
func ink(in pdf: Data) throws -> Int {
    try raster(pdf).dark.count { $0 }
}

/// A stroke of bare coordinates: geometry tests need neither colour nor pressure.
func stroke(points: [(Float, Float)], tool: PenTool = .fineliner1) -> Stroke {
    Stroke(
        tool: tool,
        color: .black,
        thicknessScale: 1,
        points: points.map { StrokePoint(x: $0.0, y: $0.1, width: 2, pressure: 1) }
    )
}

/// A white page to draw a probe on, and the bytes behind it. One byte per
/// pixel: the template ink is grey (`Calibration.templateStroke`), so any
/// value short of white is a line.
func probeCanvas(width: Int, height: Int) throws -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let context = try #require(CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height)
    return (context, pixels)
}

/// The rows carrying ink. A bitmap context holds the top row first while the
/// renderer counts template coordinates downwards from the top, so a row here
/// is a template `y` less one.
func inkedRows(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> [Int] {
    (0..<height).filter { y in
        stride(from: 0, to: width, by: 8).contains { pixels[y * width + $0] < 250 }
    }
}
