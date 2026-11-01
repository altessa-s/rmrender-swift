// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMLines
@testable import RMRender
import Testing

// The file itself: what the parser keeps, skips and refuses.

// A hidden layer keeps everything it holds: the strokes are in the file with
// every one of their points, and it is the layer that is put away, not its
// contents. Draw them anyway and the user sees what they hid — quietly, with
// nothing to say it happened.
@Test("The strokes of a hidden layer are not drawn")
func hiddenLayerIsNotDrawn() throws {
    let shown = try RMParser.parsePage(makePage(layerVisible: true))
    let hidden = try RMParser.parsePage(makePage(layerVisible: false))

    #expect(shown.strokes.count == 1)
    #expect(hidden.strokes.isEmpty, "the layer is hidden, so its stroke is not on the page")
    // Hiding is not a loss to report: nothing failed to parse.
    #expect(hidden.skippedBlocks == shown.skippedBlocks)
}

// Rubbing something out does not take it out of the file, and a stroke rubbed
// out in the middle is not one stroke with a hole. On a live notebook
// whose last line was partly erased, ten stroke blocks appear, of which
// three carry no value at all — the tombstones of what was erased — and seven
// carry the surviving pieces. The tablet deletes the item and adds the pieces
// as items of their own, the way a CRDT does everything.
//
// So there is nothing to subtract and no eraser stroke to skip: the erased part
// simply is not in the file as anything drawable. What matters is that a block
// without a value is read as erased rather than as a page we failed to parse —
// on a long-edited page there is more erased than left.
@Test("An erased stroke is not drawn and not counted as a loss")
func erasedStrokeIsNotALoss() throws {
    let page = try RMParser.parsePage(makePage(erased: true))

    #expect(page.strokes.isEmpty)
    // Not among the skipped: the user rubbed it out, and calling that a loss
    // would raise an alarm on every page anybody has edited.
    #expect(page.skippedBlocks == 0)
}

// The user can hide the page's template and the imported PDF behind it, and
// both switches are written into the scene info block. Unread, they made the
// volume draw what the tablet does not show — with nothing to say why.
@Test("The visibility of the background and the source document is read")
func sceneInfoVisibilityFlagsAreRead() throws {
    let header = RMParser.header.utf8.count
    let stroke = makePage()
    func page(_ block: [UInt8]) -> Data {
        Data(Array(stroke.prefix(header)) + block + Array(stroke.dropFirst(header)))
    }

    let hidden = try RMParser.parsePage(
        page(sceneInfoBlock(backgroundVisible: false, rootDocumentVisible: false))
    )
    #expect(hidden.backgroundVisible == false)
    #expect(hidden.rootDocumentVisible == false)
    // The size still reads from the same block: the flags stand before it.
    #expect(hidden.paperSize == CGSize(width: 1620, height: 2160))

    let shown = try RMParser.parsePage(
        page(sceneInfoBlock(backgroundVisible: true, rootDocumentVisible: true))
    )
    #expect(shown.backgroundVisible == true)
    #expect(shown.rootDocumentVisible == true)

    // A block without the flags means "never touched", and that means shown.
    let untouched = try RMParser.parsePage(
        page(sceneInfoBlock(backgroundVisible: nil, rootDocumentVisible: nil))
    )
    #expect(untouched.backgroundVisible == true)
    #expect(untouched.rootDocumentVisible == true)
}

// MARK: - Layers

/// A record of the scene tree (`0x01`): a node entering or leaving the tree.
/// An adding record names its node in tag 1; a removing one is a fresh record
/// whose tag 2 names the node taken out.
private func sceneTreeBlock(
    record: (author: UInt8, counter: UInt64),
    target: (author: UInt8, counter: UInt64) = (0, 0),
    inTree: Bool,
    parent: (author: UInt8, counter: UInt64) = (0, 1)
) -> [UInt8] {
    var payload = FixtureWriter()
    payload.appendID(index: 1, record)
    payload.appendID(index: 2, target)
    payload.appendTag(index: 3, type: 0x1)
    payload.append(inTree ? 1 : 0)
    var parentValue = FixtureWriter()
    parentValue.appendID(index: 1, parent)
    payload.appendBlock(index: 4, parentValue.bytes)

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)
    block.append(1)
    block.append(1)
    block.append(0x01)                                    // scene tree
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

/// A group's place in its parent's chain (`0x04`). A tombstone carries the
/// deletion count and no node at all — the reference goes out with it.
private func groupItemBlock(
    parent: (author: UInt8, counter: UInt64) = (0, 1),
    item: (author: UInt8, counter: UInt64),
    left: (author: UInt8, counter: UInt64),
    deleted: UInt32 = 0,
    node: (author: UInt8, counter: UInt64)? = nil
) -> [UInt8] {
    var payload = FixtureWriter()
    payload.appendID(index: 1, parent)
    payload.appendID(index: 2, item)
    payload.appendID(index: 3, left)
    payload.appendID(index: 4, (author: 0, counter: 0))   // right
    payload.appendTag(index: 5, type: 0x4)
    payload.append(uint32: deleted)
    if let node {
        var value = FixtureWriter()
        value.append(0x02)                                // value type: group
        value.appendID(index: 2, node)
        payload.appendTag(index: 6, type: 0xC)
        payload.append(uint32: UInt32(value.bytes.count))
        payload.append(contentsOf: value.bytes)
    }

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)
    block.append(1)
    block.append(1)
    block.append(0x04)                                    // group item
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

/// A reordering: three layers, "Layer 3" dragged to the
/// bottom. The chain after the edit, as written — two tombstones
/// from the drag, the living record at the head:
///
/// ```
///    0:13 left=0:0   del=0 → Layer 1      1:32 left=0:13  del=1
///    1:22 left=0:13  del=0 → Layer 2      1:34 left=0:0   del=0 → Layer 3
///    1:26 left=1:22  del=1
/// ```
private func reorderedLayersPage(removeLayer: (author: UInt8, counter: UInt64)? = nil) -> Data {
    let layer1: (author: UInt8, counter: UInt64) = (0, 11)
    let layer2: (author: UInt8, counter: UInt64) = (1, 18)
    let layer3: (author: UInt8, counter: UInt64) = (1, 23)

    var blocks: [UInt8] = []
    blocks += sceneTreeBlock(record: layer1, inTree: true)
    blocks += sceneTreeBlock(record: layer2, inTree: true)
    blocks += sceneTreeBlock(record: layer3, inTree: true)
    if let removeLayer {
        blocks += sceneTreeBlock(record: (1, 38), target: removeLayer, inTree: false, parent: (0, 0))
    }
    blocks += groupItemBlock(item: (0, 13), left: (0, 0), node: layer1)
    blocks += groupItemBlock(item: (1, 22), left: (0, 13), node: layer2)
    blocks += groupItemBlock(item: (1, 26), left: (1, 22), deleted: 1)
    blocks += groupItemBlock(item: (1, 32), left: (0, 13), deleted: 1)
    blocks += groupItemBlock(item: (1, 34), left: (0, 0), node: layer3)

    // The strokes lie in the file in their original order — a reordering
    // rewrites no stroke at all, so file order cannot be trusted.
    let header = RMParser.header.utf8.count
    func stroke(_ color: PenColor, parent: (author: UInt8, counter: UInt64), item: UInt64) -> [UInt8] {
        Array(
            makePage(color: UInt32(color.rawValue), parent: parent, item: (1, item), left: (0, 0))
                .dropFirst(header)
        )
    }
    let head = Array(makePage().prefix(header))
    return Data(
        head + blocks
            + stroke(.black, parent: layer1, item: 101)
            + stroke(.red, parent: layer2, item: 102)
            + stroke(.blue, parent: layer3, item: 103)
    )
}

// The file order of strokes stops being the order of layers the moment the
// user reorders them: the tablet rewrites the chain of `0x04` and not one
// stroke. The head of the chain is the bottom layer, drawn first; a tie
// between records sharing a `left` goes to the newer identifier.
@Test("Layers draw in 0x04 chain order, not file order")
func layersDrawInChainOrderNotFileOrder() throws {
    let page = try RMParser.parsePage(reorderedLayersPage())
    // Layer 3 was dragged to the bottom: its stroke is drawn first, though
    // its block lies last in the file.
    #expect(page.strokes.map(\.color) == [.blue, .black, .red])
}

// A deleted layer is present in `0x02` (name, visible) and in `0x04` (its
// chain record), and absent only from the tree — `0x01` is the one authority.
// Locally the tablet wipes the strokes too, but a merge of two devices makes
// no such promise, so the parser must not lean on the wipe.
@Test("A layer removed via 0x01 is not drawn even with its 0x02 and 0x04 present")
func removedLayerIsNotDrawn() throws {
    let page = try RMParser.parsePage(reorderedLayersPage(removeLayer: (1, 18)))
    #expect(page.strokes.map(\.color) == [.blue, .black], "Layer 2 is out of the tree")
}

/// A page edited on two tablets at once: each
/// added a "Layer 2" after Layer 1 — item 16 of its own author, the same
/// counter, the same `left` — and put one stroke on it.
///
/// ```
///    0:13 left=0:0   → Layer 1 (0:11)
///    1:16 left=0:13  → Layer 2 (1:14), stroke 1:18 red
///    2:16 left=0:13  → Layer 2 (2:14), stroke 2:18 cyan
/// ```
private func twoDeviceLayersPage() -> Data {
    let layer1: (author: UInt8, counter: UInt64) = (0, 11)
    let first: (author: UInt8, counter: UInt64) = (1, 14)
    let second: (author: UInt8, counter: UInt64) = (2, 14)
    var blocks: [UInt8] = []
    blocks += sceneTreeBlock(record: layer1, inTree: true)
    blocks += sceneTreeBlock(record: first, inTree: true)
    blocks += sceneTreeBlock(record: second, inTree: true)
    blocks += groupItemBlock(item: (0, 13), left: (0, 0), node: layer1)
    blocks += groupItemBlock(item: (1, 16), left: (0, 13), node: first)
    blocks += groupItemBlock(item: (2, 16), left: (0, 13), node: second)
    let header = RMParser.header.utf8.count
    func stroke(
        _ color: PenColor,
        parent: (author: UInt8, counter: UInt64),
        item: (author: UInt8, counter: UInt64)
    ) -> [UInt8] {
        Array(
            makePage(color: UInt32(color.rawValue), parent: parent, item: item, left: (0, 0))
                .dropFirst(header)
        )
    }
    let head = Array(makePage().prefix(header))
    return Data(
        head + blocks
            + stroke(.red, parent: first, item: (1, 18))
            + stroke(.cyan, parent: second, item: (2, 18))
    )
}

// Two counters tie only across authors, and there the tablet draws the
// higher author's layer over the lower's: an exported PDF of such a page
// shows the cyan stroke over the red where the two cross. The counter rule is
// the other way — the newer identifier goes first — so the two are kept
// apart.
@Test("Layers added by two devices at once: the higher author draws on top")
func twoDeviceLayersOrderByAuthor() throws {
    let page = try RMParser.parsePage(twoDeviceLayersPage())
    #expect(page.strokes.map(\.color) == [.red, .cyan])
}

// MARK: - Images

/// The attachment map (`0x0E`): one entry, key to file name.
private func attachmentMapBlock(key: [UInt8], file: String) -> [UInt8] {
    var inner = FixtureWriter()
    inner.appendID(index: 1, (author: 0, counter: 0))
    var string = FixtureWriter()
    string.append(varuint: UInt64(file.utf8.count))
    string.append(1)                                      // encoding marker
    string.append(contentsOf: Array(file.utf8))
    inner.appendBlock(index: 2, string.bytes)
    inner.appendTag(index: 2, type: 0x4)
    inner.append(uint32: 2)
    inner.appendTag(index: 1, type: 0x1)
    inner.append(17)

    var entry = FixtureWriter()
    entry.append(contentsOf: key)                         // 16 opaque bytes
    entry.appendBlock(index: 1, inner.bytes)

    var list = FixtureWriter()
    list.append(varuint: 1)
    list.appendBlock(index: 0, entry.bytes)

    var payload = FixtureWriter()
    payload.appendBlock(index: 1, list.bytes)

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)
    block.append(3)
    block.append(3)
    block.append(0x0E)                                    // attachment map
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

/// One corner of a placed image: where it lands on the sheet, and which
/// corner of the picture goes there.
private struct ImageVertex {
    var x: Float
    var y: Float
    var u: Float
    var v: Float
}

/// An image on the page (`0x0F`): the preamble, the key, four vertices.
private func imageItemBlock(
    parent: (author: UInt8, counter: UInt64) = (1, 1),
    item: (author: UInt8, counter: UInt64),
    left: (author: UInt8, counter: UInt64) = (0, 0),
    key: [UInt8],
    vertices: [ImageVertex]
) -> [UInt8] {
    var value = FixtureWriter()
    value.append(0x07)                                    // value type: image
    var reference = FixtureWriter()
    reference.appendID(index: 1, (author: 0, counter: 0))
    // The key travels in a tag-2 wrapper of its own.
    reference.appendBlock(index: 2, key)
    value.appendBlock(index: 1, reference.bytes)
    value.appendID(index: 2, (author: 0, counter: 0))
    var corners = FixtureWriter()
    corners.append(varuint: UInt64(vertices.count * 4))
    for vertex in vertices {
        corners.append(float: vertex.x)
        corners.append(float: vertex.y)
        corners.append(float: vertex.u)
        corners.append(float: vertex.v)
    }
    value.appendBlock(index: 3, corners.bytes)

    var payload = FixtureWriter()
    payload.appendID(index: 1, parent)
    payload.appendID(index: 2, item)
    payload.appendID(index: 3, left)
    payload.appendID(index: 4, (author: 0, counter: 0))
    payload.appendTag(index: 5, type: 0x4)
    payload.append(uint32: 0)
    payload.appendBlock(index: 6, value.bytes)

    var block = FixtureWriter()
    block.append(uint32: UInt32(payload.bytes.count))
    block.append(0)
    block.append(2)
    block.append(2)
    block.append(0x0F)                                    // image item
    block.append(contentsOf: payload.bytes)
    return block.bytes
}

// Skipping the blocks by length leaves a page of captures blank:
// nothing of a capture lives anywhere else — the tablet
// rasterises it whole (PLAN-TEXT).
@Test("An image is read: name from the attachment map, vertices, place in the sequence")
func imageBlocksAreRead() throws {
    let key: [UInt8] = Array(0..<16)
    let strokePage = makePage(parent: (1, 1), item: (1, 10), left: (0, 0))
    let header = RMParser.header.utf8.count
    let data = Data(
        Array(strokePage.prefix(header))
            + attachmentMapBlock(key: key, file: "d28d67b2.jpg")
            + imageItemBlock(
                item: (1, 20),
                left: (1, 10),
                key: key,
                vertices: [
                    ImageVertex(x: 101.17, y: -131.60, u: 0, v: 0),
                    ImageVertex(x: 1061.17, y: -131.60, u: 1, v: 0),
                    ImageVertex(x: 1061.17, y: 828.40, u: 1, v: 1),
                    ImageVertex(x: 101.17, y: 828.40, u: 0, v: 1),
                ]
            )
            + Array(strokePage.dropFirst(header))
    )

    let page = try RMParser.parsePage(data)
    let image = try #require(page.images.first)
    #expect(image.file == "d28d67b2.jpg")
    #expect(image.vertices.count == 4)
    #expect(abs(image.vertices[0].x - 101.17) < 0.01)
    #expect(abs(image.vertices[2].u - 1) < 0.001)
    // The image hangs on the first stroke in the chain: one stroke before it.
    #expect(image.strokesBefore == 1)

    // A key the map does not know is content we cannot fetch — the image is
    // dropped with a log line, not crashed on.
    let orphan = Data(
        Array(strokePage.prefix(header))
            + imageItemBlock(item: (1, 20), key: Array(repeating: 9, count: 16), vertices: [
                ImageVertex(x: 0, y: 0, u: 0, v: 0),
                ImageVertex(x: 1, y: 0, u: 1, v: 0),
                ImageVertex(x: 1, y: 1, u: 1, v: 1),
                ImageVertex(x: 0, y: 1, u: 0, v: 1),
            ])
            + Array(strokePage.dropFirst(header))
    )
    #expect(try RMParser.parsePage(orphan).images.isEmpty)
}

// The file numbers the characters of the text in Unicode scalars, not in
// grapheme clusters: an Arabic vowel mark is a scalar of its own and gets an
// identifier, while a grapheme count swallows it into its base letter. Read
// by graphemes, every style key and anchor after the first diacritic would
// point one short per diacritic, and styles and anchors would land on the
// wrong character.
@Test("Characters are numbered in scalars: a style behind an Arabic diacritic finds its paragraph")
func charactersAreNumberedInScalars() throws {
    // "مُا" — letter, diacritic, letter: three scalars, two graphemes. Then
    // a newline and a second paragraph. The second paragraph's style key is
    // the newline's id by the scalar count: 10 + 3 = counter 13.
    let records = [TextRecord(id: (1, 10), left: (0, 0), text: "مُا\nвторой")]
    let styles = [StyleRecord(key: (1, 13), style: 2)]
    let page = try RMParser.parsePage(makeTextPage(records: records, styles: styles))
    let text = try #require(page.text)
    #expect(text.lines.count == 2)
    #expect(text.formats[1]?.style == .heading, "the style found its paragraph by the scalar key")
}

// The horizontal of an anchor is written in the file — `anchor_origin_x`,
// tag 10 of the tree node — skipping it and recomputing from our own
// layout fails on the boundary of two writing directions, where the layout cannot know the
// answer: the file and the layout genuinely disagree there.
@Test("The anchor's horizontal is read from the file, not recomputed")
func anchorOriginXIsReadFromTheFile() throws {
    let page = try RMParser.parsePage(makeAnchoredPage(originX: 572.0))
    #expect(page.anchoredStrokes == 1)
    let anchor = try #require(page.strokes.first?.anchor)
    // Character (1, 12) is the third of "one two", and the pen stands past it.
    #expect(anchor.paragraph == 0)
    #expect(anchor.offset == 3)
    #expect(anchor.originX == 572.0)

    // The wrapped spelling — a last-write-wins record — reads the same.
    let wrapped = try RMParser.parsePage(makeAnchoredPage(originX: -244.0625, wrapped: true))
    #expect(wrapped.strokes.first?.anchor?.originX == -244.0625)

    // A file without the field keeps the computed path: nothing pretends the
    // number was there.
    let absent = try RMParser.parsePage(makeAnchoredPage(originX: nil))
    #expect(absent.strokes.first?.anchor?.originX == nil)
    #expect(absent.strokes.first?.anchor == TextAnchor(paragraph: 0, offset: 3))
}

@Test("A page with no visibility flag at all is drawn in full")
func aPageWithoutVisibilityIsDrawn() throws {
    // An untouched layer carries no flag. Absent has to mean shown: read the
    // other way round, an ordinary notebook would come out blank.
    let page = try RMParser.parsePage(makePage())
    #expect(page.strokes.count == 1)
}

// Bold and italic are nowhere in the list of paragraph styles: a paragraph with
// a bold word calls itself plain, and the markup lives on the characters — a
// pair of records of no text at all, fencing the stretch off, with the sign
// inside their value. Read only the styles and the emphasis vanishes without a
// word.
@Test("A bold stretch is read off the records that fence it")
func readsBoldRun() throws {
    let page = try RMParser.parsePage(
        makeTextPage(records: [
            TextRecord(id: (1, 10), left: (0, 0), text: "ab"),
            TextRecord(id: (1, 50), left: (1, 11), faceMark: 1),      // bold on
            TextRecord(id: (1, 20), left: (1, 50), text: "cd"),
            TextRecord(id: (1, 51), left: (1, 21), faceMark: 2),      // bold off
            TextRecord(id: (1, 30), left: (1, 51), text: "ef"),
        ])
    )
    let text = try #require(page.text)

    #expect(text.lines == ["abcdef"], "the marks are not characters and take no room")
    #expect(text.faces[0] == [FaceRun(range: 2..<4, bold: true, italic: false)])
}

@Test("Italic has marks of its own, not the same pair as bold")
func readsItalicRun() throws {
    // Odd switches on and even switches off, but the numbers differ by face:
    // were it one pair for both, italic would carry 1 and 2 as well.
    let page = try RMParser.parsePage(
        makeTextPage(records: [
            TextRecord(id: (1, 10), left: (0, 0), text: "ab"),
            TextRecord(id: (1, 50), left: (1, 11), faceMark: 3),      // italic on
            TextRecord(id: (1, 20), left: (1, 50), text: "cd"),
        ])
    )
    let text = try #require(page.text)

    #expect(text.faces[0] == [FaceRun(range: 2..<4, bold: false, italic: true)])
}

@Test("A face that is never switched off runs to the end of the line, and no further")
func faceEndsWithTheLine() throws {
    let page = try RMParser.parsePage(
        makeTextPage(records: [
            TextRecord(id: (1, 50), left: (0, 0), faceMark: 1),
            TextRecord(id: (1, 10), left: (1, 50), text: "ab\ncd"),
        ])
    )
    let text = try #require(page.text)

    #expect(text.lines == ["ab", "cd"])
    // A stretch belongs to a line: two lines, two of them, each counted from
    // the start of its own line.
    #expect(text.faces[0] == [FaceRun(range: 0..<2, bold: true, italic: false)])
    #expect(text.faces[1] == [FaceRun(range: 0..<2, bold: true, italic: false)])
}

// `tag 1` is not the whole style. Two paragraphs both carrying 3 are drawn by
// the tablet at 46 and at 36, and the only thing between them is whether the
// record goes on. Reading the first field and stopping ran the two together.
@Test("A style record that goes on is a different paragraph")
func readsFurtherStyleFields() throws {
    let page = try RMParser.parsePage(
        makeTextPage(
            records: [TextRecord(id: (1, 10), left: (0, 0), text: "one\ntwo")],
            styles: [
                StyleRecord(key: (0, 0), style: 3),
                // Keyed by the newline that ends the first paragraph: the
                // style belongs to the line after it.
                StyleRecord(key: (1, 13), style: 3, furtherFields: true),
            ]
        )
    )
    let text = try #require(page.text)

    #expect(text.formats[0] == ParagraphFormat(style: .subheading, hasFurtherFields: false))
    #expect(text.formats[1] == ParagraphFormat(style: .subheading, hasFurtherFields: true))
}

// The width is in the file outright, and reading it needs no assumption about
// where the column sits on the sheet.
@Test("The column width is read from the field, not worked out from the origin")
func readsColumnWidth() throws {
    let declared = try RMParser.parsePage(
        makeTextPage(
            records: [TextRecord(id: (1, 10), left: (0, 0), text: "one")],
            origin: (-370, 200),
            // A float32 under a `byte4` tag: read as a `uint32` these same
            // bytes are a billion and change.
            columnWidth: 740
        )
    )
    #expect(try #require(declared.text).columnWidth == 740)

    let silent = try RMParser.parsePage(
        makeTextPage(records: [TextRecord(id: (1, 10), left: (0, 0), text: "one")])
    )
    #expect(try #require(silent.text).columnWidth == nil, "no field, no answer to invent")
}

@Test("An explicit colour wins over the palette index")
func readsExplicitColour() throws {
    // The highlighter gives every highlight the same palette index and writes
    // the real colour into the tail: without it pink and orange collapse
    // into yellow.
    let orange = try RMParser.parsePage(
        makePage(
            tool: UInt32(PenTool.highlighter2.rawValue),
            color: UInt32(PenColor.highlight.rawValue),
            argb: 0xffff_c38c
        )
    )
    let stroke = try #require(orange.strokes.first)

    #expect(stroke.color == .highlight, "the palette index is still read")
    #expect(stroke.argb == 0xffff_c38c)
    #expect(abs(stroke.rgb.red - 1) < 0.01)
    #expect(abs(stroke.rgb.green - 195.0 / 255) < 0.01)
    #expect(abs(stroke.rgb.blue - 140.0 / 255) < 0.01)

    let pink = try RMParser.parsePage(
        makePage(
            tool: UInt32(PenTool.highlighter2.rawValue),
            color: UInt32(PenColor.highlight.rawValue),
            argb: 0xfff2_9eff
        )
    )
    #expect(
        try #require(pink.strokes.first).rgb != stroke.rgb,
        "two highlights with the same palette index must not look alike"
    )
}

@Test("Without an explicit colour the palette still rules")
func fallsBackToPaletteWithoutExplicitColour() throws {
    let page = try RMParser.parsePage(makePage(color: UInt32(PenColor.red.rawValue)))
    let stroke = try #require(page.strokes.first)

    #expect(stroke.argb == nil, "a file without the colour tail carries no explicit colour")
    #expect(stroke.rgb == PenColor.red.rgb)
}

@Test("A stroke parses with all its fields")
func parsesStroke() throws {
    let page = try RMParser.parsePage(makePage())

    #expect(page.strokes.count == 1)
    let stroke = try #require(page.strokes.first)
    #expect(stroke.tool == .fineliner1)
    #expect(stroke.color == .blue)
    #expect(stroke.thicknessScale == 2)
    #expect(stroke.points.count == 2)
    #expect(stroke.points[1].x == 10)
    #expect(stroke.points[1].y == 20)
    #expect(page.skippedBlocks == 0)
}

@Test("A foreign header gives a clear error, not garbage on the page")
func rejectsForeignHeader() {
    let data = Data("not that format at all, honestly".utf8)
    #expect(throws: ParseError.self) {
        try RMParser.parsePage(data)
    }
}

@Test("An unknown block is skipped and counted")
func countsUnknownBlocks() throws {
    // A type this version has never seen. It is stepped over by length, and
    // that — not the reading of a block we do understand — is what the count
    // is for.
    let page = try RMParser.parsePage(makePage(blockType: 0x06))

    #expect(page.strokes.isEmpty)
    #expect(page.skippedBlocks == 1)
}

@Test("A page we read in full counts nothing as skipped")
func aFullyReadPageSkipsNothing() throws {
    // The count says "blocks we did not understand": the text, the scene
    // tree, the attachments and the rest each have a parser and must not
    // count themselves. A typed page claiming losses it had not suffered
    // would be the same disservice as claiming none when it had.
    let typed = try RMParser.parsePage(
        makeTextPage(records: [TextRecord(id: (1, 10), left: (0, 0), text: "one two")])
    )
    #expect(typed.text != nil, "the fixture has to carry text for this test to say anything")
    #expect(typed.skippedBlocks == 0, "nothing was lost, so nothing should be counted")

    // And a page of plain handwriting, which carries a scene tree and its
    // nodes beside the strokes.
    let drawn = try RMParser.parsePage(makePage())
    #expect(!drawn.strokes.isEmpty)
    #expect(drawn.skippedBlocks == 0)
}

@Test("The service blocks every page opens with are not a loss")
func serviceQuartetIsNotCounted() throws {
    // `09 00 0a` stand in front of the scene on every page the tablet writes.
    // Counted as blocks that could not be read, they would put three on
    // every page and three hundred on a hundred-page book — a number in which
    // a real loss could not be seen.
    let withService = try RMParser.parsePage(makePage())
    let bare = try RMParser.parsePage(makePage(service: false))

    #expect(withService.skippedBlocks == 0)
    #expect(bare.skippedBlocks == 0)
    #expect(withService.strokes.count == bare.strokes.count)
}

// MARK: - A file that lies about its own sizes

// Everything below is one class of defect: a count in the file is a
// declaration, not a measurement. Believed, it either traps the process — a
// trap goes past every `try?` in the parser and takes the caller with it —
// or reserves memory nobody has. Each of these fixtures is a page that
// declares one thing and carries another, and the answer has to be the same
// every time: the parse returns, the page survives, and the loss is counted.

@Test("A stroke declaring more points than it carries is one lost stroke")
func rejectsPointsRunningPastTheValue() throws {
    // Three hundred million points at sixteen bytes apiece is five gigabytes,
    // asked for by a file of a hundred bytes. What this pins is the outcome —
    // the stroke lost, said to be lost, the page and the process going on;
    // the size of the reservation is not visible from here, and a test that
    // pretended to measure it would measure the machine instead.
    let page = try RMParser.parsePage(makePage(pointsLength: 0xFFFF_FF00))

    #expect(page.strokes.isEmpty)
    #expect(page.skippedBlocks == 1, "the stroke is a loss, and the count is where losses are said")
}

@Test("The unrounded canvas wins over the rounded sheet, and a page with only one still has a sheet")
func theCanvasOutranksTheRoundedSheet() throws {
    // Tag 5 is the sheet in whole units, tag 7 the same sheet as two float64 —
    // and the difference is visible: a Move's canvas is 820.295 × 1458.303
    // where tag 5 says 820 × 1458, and the tablet's own export is built from
    // the unrounded one. Read after tag 5 on purpose, so that it wins.
    let stroke = makePage()
    let header = RMParser.header.utf8.count
    func page(_ block: [UInt8]) -> Data {
        Data(Array(stroke.prefix(header)) + block + Array(stroke.dropFirst(header)))
    }

    let both = try RMParser.parsePage(
        page(sceneInfoBlock(
            backgroundVisible: nil,
            rootDocumentVisible: nil,
            size: (820, 1458),
            canvas: (820.2953, 1458.3029)
        ))
    )
    let size = try #require(both.paperSize)
    #expect(abs(size.width - 820.2953) < 0.0001)
    #expect(abs(size.height - 1458.3029) < 0.0001)

    // A page carrying only the rounded one still has a sheet: most do.
    let rounded = try RMParser.parsePage(
        page(sceneInfoBlock(backgroundVisible: nil, rootDocumentVisible: nil, size: (1620, 2160)))
    )
    #expect(rounded.paperSize == CGSize(width: 1620, height: 2160))

    // And only the exact one is enough by itself.
    let exact = try RMParser.parsePage(
        page(sceneInfoBlock(
            backgroundVisible: nil,
            rootDocumentVisible: nil,
            size: nil,
            canvas: (1404.5, 1872.25)
        ))
    )
    #expect(exact.paperSize == CGSize(width: 1404.5, height: 1872.25))
}

@Test("Text records read in CRDT order: a shared left, a deletion, and file order last of all")
func textReadsInCrdtOrderNotFileOrder() throws {
    // The chain, written backwards. Each record hangs off the last character
    // of the one before it — "two " off "one "'s fourth character, and
    // "three" off the third character a deletion of no text still holds. A
    // deletion keeps its place in the sequence, so the link counts past it,
    // and sorting by the counter would put these four in the order they lie.
    let start: (author: UInt8, counter: UInt64) = (0, 0)
    let chained = try RMParser.parsePage(
        makeTextPage(records: [
            TextRecord(id: (1, 40), left: (1, 32), text: "three"),
            TextRecord(id: (1, 30), left: (1, 23), deleted: 3),
            TextRecord(id: (1, 20), left: (1, 13), text: "two "),
            TextRecord(id: (1, 10), left: start, text: "one "),
        ])
    )
    #expect(try #require(chained.text).lines == ["one two three"])

    // The tie: two records hanging off the very same character. Which of them
    // comes first is said by the right link — "one " names "two ", so it
    // stands before it, whatever the order they lie in.
    let tied = try RMParser.parsePage(
        makeTextPage(records: [
            TextRecord(id: (1, 20), left: start, text: "two "),
            TextRecord(id: (1, 10), left: start, text: "one ", right: (1, 20)),
        ])
    )
    #expect(try #require(tied.text).lines == ["one two "])

    // And the same pair with the link the other way round reads the other
    // way round: the assertion above is about the link, not about the file.
    let reversed = try RMParser.parsePage(
        makeTextPage(records: [
            TextRecord(id: (1, 10), left: start, text: "one "),
            TextRecord(id: (1, 20), left: start, text: "two ", right: (1, 10)),
        ])
    )
    #expect(try #require(reversed.text).lines == ["two one "])
}

@Test("A deep chain of groups is walked without the call stack")
func deeplyNestedGroupsAreWalkedIteratively() throws {
    // Groups nest as deeply as the file says, and the depth is not the
    // tablet's to promise — a merge, or a blob somebody corrupted, is enough.
    // Recursion here died on the stack, and a stack overflow is not an error
    // anything catches: it is the end of the process, and the process is the
    // extension. Two thousand deep, which is past what a task's stack holds.
    let depth = 2000
    var blocks: [UInt8] = []
    for level in 0..<depth {
        let parent: (author: UInt8, counter: UInt64) = (1, UInt64(level + 1))
        let child: (author: UInt8, counter: UInt64) = (1, UInt64(level + 2))
        blocks += sceneTreeBlock(record: child, inTree: true)
        blocks += groupItemBlock(
            parent: parent, item: (2, UInt64(level + 1)), left: (0, 0), node: child
        )
    }
    // The stroke sits at the bottom of the chain.
    let deepest: (author: UInt8, counter: UInt64) = (1, UInt64(depth + 1))
    let stroke = makePage(parent: deepest, item: (3, 1), left: (0, 0), service: false)
    let header = RMParser.header.utf8.count
    var file: [UInt8] = Array(RMParser.header.utf8)
    file += serviceBlocks()
    file += blocks
    file += Array(stroke.dropFirst(header))
    let page = try RMParser.parsePage(Data(file))

    #expect(page.strokes.count == 1, "the stroke at the bottom of the chain is drawn")
    #expect(page.skippedBlocks == 0)
}

@Test("A value declared longer than its block does not widen what the points may claim")
func rejectsValueRunningPastTheBlock() throws {
    // The points are bounded by the end of their value — and the value's own
    // length is another number out of the same file. Left unchecked against
    // the block, it would move that bound as far as it liked, and the first
    // guard would be worth nothing.
    let page = try RMParser.parsePage(makePage(pointsLength: 0xFFFF_FF00, valueLength: 0xFFFF_FF00))

    #expect(page.strokes.isEmpty)
    #expect(page.skippedBlocks == 1)
}

@Test("A highlight declaring more rectangles than it carries loses only itself")
func rejectsRectangleCountBeyondTheBlock() throws {
    let honest = try RMParser.parsePage(makeHighlightPage())
    #expect(honest.highlights.count == 1)
    #expect(honest.skippedBlocks == 0)

    // A billion rectangles is thirty-two gigabytes of reservation on the word
    // of a block that holds one.
    let inflated = try RMParser.parsePage(makeHighlightPage(declaredCount: 1_000_000_000))
    #expect(inflated.highlights.isEmpty)
    #expect(inflated.skippedBlocks == 1)

    // And the count that is not an `Int` at all.
    let impossible = try RMParser.parsePage(makeHighlightPage(declaredCount: .max))
    #expect(impossible.highlights.isEmpty)
    #expect(impossible.skippedBlocks == 1)
}

// MARK: - A file whose numbers are not numbers

// One floor below the section above: not a count that lies about a size, but
// a coordinate that is no coordinate at all. NaN and ±Inf pass through
// `CGRect`, `CGPath` and CoreGraphics without a word and come out in the sheet
// the page is drawn on — and whether anybody notices depends on where in the
// stroke the number sat, because `min` and `max` keep whichever argument they
// were handed first. So the answer is not a check at drawing time but a refusal
// at the parse: what comes out of the file is a number or it is not there.

/// Every corner of the box is a number. `CGRect` has no such question of its
/// own — `isInfinite` names the one special infinite rect and `isNull` the
/// empty one, and neither of them sees a NaN that arrived by arithmetic.
private func isFinite(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
}

@Test("A stroke with a point that is not a number is lost whole, counted, and leaves a finite sheet")
func rejectsNonFinitePoints() throws {
    let wild: [(name: String, value: Float)] = [
        ("NaN", .nan), ("+Inf", .infinity), ("-Inf", -.infinity),
    ]
    for (name, value) in wild {
        // On the first point and on the last, because that is what decides the
        // outcome: a bad number as the first point poisons the bounds
        // for good, while the same number coming later is dropped in
        // silence and the page comes out looking whole.
        let places: [(where: String, points: [StrokeSample])] = [
            ("first", [StrokeSample(x: value, y: 0), StrokeSample(x: 10, y: 20)]),
            ("last", [StrokeSample(x: 0, y: 0), StrokeSample(x: 10, y: value)]),
        ]
        for place in places {
            let page = try RMParser.parsePage(makePage(points: place.points))

            #expect(page.strokes.isEmpty, "\(name) on the \(place.where) point is not a stroke to draw")
            #expect(
                page.skippedBlocks == 1,
                "\(name) on the \(place.where) point is a loss, and losses are counted"
            )
            let bounds = PageRenderer.contentBounds(
                of: page, pageSize: PageRenderer.defaultPageSize, edge: .ribbon
            )
            #expect(isFinite(bounds), "\(name) on the \(place.where) point must not reach the sheet")
        }
    }

    // And the same fixture with numbers in it still draws: the refusal is of
    // the number, not of the shape of the file.
    let honest = try RMParser.parsePage(makePage())
    #expect(honest.strokes.count == 1)
    #expect(honest.skippedBlocks == 0)
}

@Test("A canvas of infinite size is no size at all")
func rejectsNonFiniteCanvas() throws {
    let stroke = makePage()
    let header = RMParser.header.utf8.count
    func page(_ block: [UInt8]) -> Data {
        Data(Array(stroke.prefix(header)) + block + Array(stroke.dropFirst(header)))
    }

    // `width > 0` reads as a check of both, and it is not: NaN fails the
    // comparison on its own, `+Inf` passes it. A page carrying only that got a
    // sheet of infinite size, which is a PDF nothing opens.
    let wild: [(width: Double, height: Double)] = [
        (.infinity, .infinity), (.nan, .nan), (820.29, .infinity),
    ]
    for canvas in wild {
        let parsed = try RMParser.parsePage(page(sceneInfoBlock(
            backgroundVisible: nil, rootDocumentVisible: nil, size: nil, canvas: canvas
        )))
        #expect(parsed.paperSize == nil, "\(canvas) is not a sheet, so the page has none")
        // Not counted, and on purpose: the scene info block loses no content
        // when a field of it is refused — the sheet falls back to the
        // renderer's own, and nothing the user drew is missing.
        #expect(parsed.skippedBlocks == 0)
    }

    // The rounded sheet beside it still stands: refusing tag 7 must not cost
    // the page the size it does have.
    let rounded = try RMParser.parsePage(page(sceneInfoBlock(
        backgroundVisible: nil, rootDocumentVisible: nil,
        size: (1620, 2160), canvas: (.infinity, .infinity)
    )))
    #expect(rounded.paperSize == CGSize(width: 1620, height: 2160))
}

@Test("A highlight rectangle that is not a rectangle takes only its own highlight")
func rejectsNonFiniteHighlightRectangles() throws {
    // The whole highlight goes rather than the one rectangle: a marker drawn
    // as a run over a line, with a hole where a rectangle was, highlights
    // something the user did not.
    let page = try RMParser.parsePage(makeHighlightPage(rectangles: [
        HighlightRect(x: 10, y: 20, width: 100, height: 30),
        HighlightRect(x: 40, y: .nan, width: 100, height: 30),
    ]))

    #expect(page.highlights.isEmpty)
    #expect(page.skippedBlocks == 1)
    #expect(page.strokes.isEmpty, "the fixture carries no strokes, and none appeared")
}

@Test("An image placed at a vertex that is not a number is a loss, not an erasure")
func rejectsNonFiniteImageVertices() throws {
    let key: [UInt8] = Array(0..<16)
    let strokePage = makePage(parent: (1, 1), item: (1, 10), left: (0, 0))
    let header = RMParser.header.utf8.count
    let data = Data(
        Array(strokePage.prefix(header))
            + attachmentMapBlock(key: key, file: "d28d67b2.jpg")
            + imageItemBlock(
                item: (1, 20),
                left: (1, 10),
                key: key,
                vertices: [
                    ImageVertex(x: 101.17, y: -131.60, u: 0, v: 0),
                    ImageVertex(x: .infinity, y: -131.60, u: 1, v: 0),
                    ImageVertex(x: 1061.17, y: 828.40, u: 1, v: 1),
                    ImageVertex(x: 101.17, y: 828.40, u: 0, v: 1),
                ]
            )
            + Array(strokePage.dropFirst(header))
    )

    let page = try RMParser.parsePage(data)
    #expect(page.images.isEmpty, "there is no placing an image on three vertices and a nonsense")
    // Counted, not passed off as a tombstone: a tombstone reads as "the user
    // erased it", and this was not erased.
    #expect(page.skippedBlocks == 1)
    #expect(page.strokes.count == 1, "the stroke beside it is untouched")
}

@Test("An unknown tool does not cancel the stroke")
func toleratesUnknownTool() throws {
    let page = try RMParser.parsePage(makePage(tool: 99, color: 77))
    let stroke = try #require(page.strokes.first)

    #expect(stroke.tool == nil, "the tool is unknown")
    #expect(stroke.color == .black, "a default colour instead of a crash")
}

@Test("A truncated file is not read past its data")
func rejectsTruncatedFile() {
    let full = makePage()
    let truncated = full.prefix(full.count - 10)

    #expect(throws: ParseError.self) {
        try RMParser.parsePage(Data(truncated))
    }
}
