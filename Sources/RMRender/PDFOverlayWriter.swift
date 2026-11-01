// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Compression
import CoreGraphics
import Foundation

/// Writing PDF objects back out.
///
/// Only what an incremental update needs: dictionaries copied from the file
/// with a key or two changed. Strings pass through as the bytes they came in
/// as — see `PDFObject.string`.
enum PDFWriter {
    static func bytes(of object: PDFObject) -> Data {
        var out = Data()
        append(object, to: &out)
        return out
    }

    /// `data` as a zlib stream, the way `/FlateDecode` wants it: the two
    /// header bytes, the deflate blocks, the Adler-32 of the input. The
    /// system encoder gives the blocks alone; the rest is wrapped here.
    /// Falls back to a stored block when the encoder declines, so that a
    /// stream is always a valid zlib stream.
    static func flate(_ data: Data) -> Data {
        var out = Data([0x78, 0x9C])
        let capacity = data.count + data.count / 100 + 64
        var encoded = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(&encoded, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        if written > 0 {
            out.append(contentsOf: encoded[0..<written])
        } else {
            // Stored blocks: uncompressed, each with its length and the
            // one's complement of it, the last one flagged final. A block
            // holds 65535 bytes at most, so the input is cut to fit.
            let blockSize = 65535
            var start = 0
            repeat {
                let end = min(start + blockSize, data.count)
                let length = UInt16(end - start)
                out.append(end == data.count ? 0x01 : 0x00)
                out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8)])
                out.append(contentsOf: [UInt8(~length & 0xFF), UInt8(~length >> 8)])
                out.append(data[data.startIndex + start..<data.startIndex + end])
                start = end
            } while start < data.count
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF)])
        out.append(contentsOf: [UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    static func append(_ object: PDFObject, to out: inout Data) {
        switch object {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .boolean(let value):
            out.append(contentsOf: Array((value ? "true" : "false").utf8))
        case .integer(let value):
            out.append(contentsOf: Array("\(value)".utf8))
        case .real(let value):
            out.append(contentsOf: Array(number(value).utf8))
        case .string(let raw):
            out.append(raw)
        case .name(let name):
            out.append(contentsOf: Array(("/" + escaped(name)).utf8))
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for item in items {
                append(item, to: &out)
                out.append(UInt8(ascii: " "))
            }
            out.append(UInt8(ascii: "]"))
        case .dictionary(let entries):
            appendDictionary(entries, to: &out)
        case .reference(let number, let generation):
            out.append(contentsOf: Array("\(number) \(generation) R".utf8))
        case .stream(let dictionary, let data):
            appendDictionary(dictionary, to: &out)
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(data)
            out.append(contentsOf: Array("\nendstream".utf8))
        }
    }

    private static func appendDictionary(_ entries: [String: PDFObject], to out: inout Data) {
        out.append(contentsOf: Array("<<".utf8))
        // Sorted so that the same input gives the same bytes: a render that
        // changes for no reason invalidates every copy already downloaded.
        for key in entries.keys.sorted() {
            out.append(contentsOf: Array(("/" + escaped(key) + " ").utf8))
            append(entries[key] ?? .null, to: &out)
            out.append(UInt8(ascii: " "))
        }
        out.append(contentsOf: Array(">>".utf8))
    }

    /// A name with the bytes a name may not carry written as `#xx`.
    private static func escaped(_ name: String) -> String {
        var out = ""
        for byte in Array(name.utf8) {
            let allowed = byte > 0x20 && byte < 0x7F && !Array("()<>[]{}/%#".utf8).contains(byte)
            out += allowed ? String(UnicodeScalar(byte)) : String(format: "#%02x", byte)
        }
        return out
    }

    /// A number the way PDF wants it: no exponent, no trailing noise.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return "\(Int(value))" }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Marks put onto a document without rebuilding it.
///
/// A PDF may be changed by appending to it: the original bytes stay where they
/// are, new objects go after them, and a new cross-reference section says what
/// the file now means. A reader follows the newest section and sees the
/// changed pages; everything not mentioned — links, outline, metadata, text —
/// is the original's own and is never touched.
///
/// That is the whole reason this exists. Redrawing a document into a new PDF
/// costs its links: for example, a live book with 624 annotations and 84
/// links came out with none.
public struct PDFOverlayWriter: Sendable {
    /// One way of laying ink over what a page already has.
    ///
    /// Named rather than numbered because the content stream refers to it by
    /// name, and carried as a list rather than as a handful of flags: a stroke's
    /// opacity comes out of the file (the alpha byte of `argb`), so how many
    /// states a page needs is a property of that page.
    public struct GraphicsState: Sendable, Hashable {
        /// The name the content stream says, without the slash.
        public let name: String
        /// The PDF blend mode, or `nil` for the ordinary one.
        public let blendMode: String?
        public let alpha: Double

        public init(name: String, blendMode: String?, alpha: Double) {
            self.name = name
            self.blendMode = blendMode
            self.alpha = alpha
        }
    }

    /// A stencil the content paints through: one bit a pixel, rows padded
    /// to a byte, nought where the colour goes — the grain of a pencil.
    ///
    /// An operator stream cannot carry pixels; they go into an object of
    /// their own that the stream names, and the writer is the one place
    /// that makes objects.
    public struct ImageMask: Sendable, Hashable {
        /// The name the content stream says, without the slash.
        public let name: String
        public let width: Int
        public let height: Int
        public let bits: Data

        public init(name: String, width: Int, height: Int, bits: Data) {
            self.name = name
            self.width = width
            self.height = height
            self.bits = bits
        }
    }

    /// What a graphics state says, without the name it is said by: the key
    /// one object is shared under, whatever each page happens to call it.
    private struct StateAppearance: Hashable {
        let blendMode: String?
        let alpha: Double
    }

    /// What goes onto one page.
    public struct Overlay: Sendable {
        /// The page of the original, counted from zero.
        public let pageIndex: Int
        /// Content stream operators, in the page's own coordinates.
        public let content: Data
        /// The states the content refers to by name.
        public let states: [GraphicsState]
        /// The stencils the content paints through, by name.
        public let images: [ImageMask]
        /// The rectangle the page is to be shown as, or `nil` to leave the
        /// original's alone.
        ///
        /// Marks that run off the sheet are drawn outside the page's box, and
        /// a reader shows the box: without this the ink is in the file and
        /// invisible. Nothing in the page's own coordinates moves — what
        /// changes is only which part of them counts as the page.
        public let box: CGRect?

        public init(
            pageIndex: Int,
            content: Data,
            states: [GraphicsState],
            images: [ImageMask] = [],
            box: CGRect? = nil
        ) {
            self.pageIndex = pageIndex
            self.content = content
            self.states = states
            self.images = images
            self.box = box
        }
    }

    /// Frozen: this framework ships in lockstep with what links it, so there is
    /// no ABI to protect — and an exhaustive `switch` over these cases in a
    /// consumer is the point. A new case must break its build, not fall into an
    /// `@unknown default`.
    @frozen
    public enum OverlayError: Error, Sendable, Equatable {
        /// The page a mark belongs to is not in the original.
        case noSuchPage(Int)
        /// A page turned by 90 degrees or more: the marks would land sideways,
        /// and no live document has needed it yet.
        case rotatedPage(Int)
    }

    public init() {}

    /// Copy the original and append the marks to the copy.
    ///
    /// The copy comes first because on APFS it costs nothing: the bytes are
    /// shared until one of the two files is written to, and the only writing
    /// here is at the end.
    public func write(original: URL, overlays: [Overlay], to output: URL) throws {
        let file = try PDFFile(url: original)
        try write(file: file, pages: try file.pages(), original: original, overlays: overlays, to: output)
    }

    /// The same, for a caller that has already read the file: the page tree of
    /// a five-hundred-page book is not worth walking twice, and the caller has
    /// to walk it anyway to know whether the overlay applies at all.
    public func write(
        file: PDFFile,
        pages: [PDFFile.Page],
        original: URL,
        overlays: [Overlay],
        to output: URL
    ) throws {
        for overlay in overlays {
            guard overlay.pageIndex >= 0, overlay.pageIndex < pages.count else {
                throw OverlayError.noSuchPage(overlay.pageIndex)
            }
            guard pages[overlay.pageIndex].rotation.isMultiple(of: 360) else {
                throw OverlayError.rotatedPage(overlay.pageIndex)
            }
        }

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: original, to: output)

        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var offset = Int(try handle.seekToEnd())

        // A file whose last byte is not a newline would run `%%EOF` into our
        // first object.
        if file.bytes.last != 0x0A {
            try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
            offset += 1
        }

        var body = Data()
        var newOffsets: [Int: Int] = [:]
        // `/Size` is the file's own word, and a word past any object number
        // the format can write is refused rather than counted on from: every
        // object this update adds is one more than the last, and one more
        // than `Int.max` is a trap. The offsets are bounded where they are
        // read (`PDFFile.objectNumberLimit`).
        let size = file.trailer["Size"]?.intValue ?? 1
        guard size <= PDFFile.objectNumberLimit else {
            throw PDFReadError.malformed("a trailer /Size of \(size)")
        }
        var nextNumber = max((file.offsets.keys.max() ?? 0) + 1, size)

        func emit(_ object: PDFObject, number: Int? = nil) -> Int {
            let assigned = number ?? nextNumber
            if number == nil { nextNumber += 1 }
            newOffsets[assigned] = offset + body.count
            body.append(contentsOf: Array("\(assigned) 0 obj\n".utf8))
            PDFWriter.append(object, to: &body)
            body.append(contentsOf: Array("\nendobj\n".utf8))
            return assigned
        }

        // The wrapper. A page's own content may leave the graphics state
        // changed — a stray `cm`, an unbalanced `q` — and our marks would
        // inherit it. A `q` before and a `Q` after cost two tiny objects and
        // make the page's own drawing none of our business.
        let openState = emit(stream("q\n"))
        let closeState = emit(stream("Q\n"))

        // One object per distinct state, however many pages ask for it — and
        // the name a page calls it by is that page's own. The content stream
        // numbers its states afresh on every page, so `/RMGs0` is the marker's
        // multiply on one page and a stroke's quarter opacity on the next; one
        // table of names for the whole document handed the second page the
        // first page's state, and a translucent stroke came out multiplied at
        // full opacity with nothing to say so. So the object is shared by what
        // it says, and the names are resolved page by page below, the way the
        // stencils already are.
        var stateObjects: [StateAppearance: Int] = [:]
        func stateObject(for state: GraphicsState) -> Int {
            let appearance = StateAppearance(blendMode: state.blendMode, alpha: state.alpha)
            if let number = stateObjects[appearance] { return number }
            var dictionary: [String: PDFObject] = ["Type": .name("ExtGState")]
            if let mode = state.blendMode { dictionary["BM"] = .name(mode) }
            dictionary["ca"] = .real(state.alpha)
            dictionary["CA"] = .real(state.alpha)
            let number = emit(.dictionary(dictionary))
            stateObjects[appearance] = number
            return number
        }

        for overlay in overlays {
            let page = pages[overlay.pageIndex]
            let marks = emit(stream(overlay.content))

            // The states by the names this page's content says them. Two
            // pages may both say `/RMGs0` and mean different things by it;
            // each gets the object for what it meant.
            var states: [String: PDFObject] = [:]
            for state in overlay.states {
                states[state.name] = .reference(number: stateObject(for: state), generation: 0)
            }

            // The stencils are the page's own: a stroke's grain is drawn
            // once, on the page it is on. Named per page as the content
            // names them; two pages may both say `/RMIm0` and mean their
            // own.
            var stencils: [String: PDFObject] = [:]
            for image in overlay.images {
                let number = emit(
                    stream(
                        [
                            "Type": .name("XObject"),
                            "Subtype": .name("Image"),
                            "ImageMask": .boolean(true),
                            "Width": .integer(image.width),
                            "Height": .integer(image.height),
                            "BitsPerComponent": .integer(1),
                            "Filter": .name("FlateDecode"),
                        ],
                        PDFWriter.flate(image.bits)
                    )
                )
                stencils[image.name] = .reference(number: number, generation: 0)
            }

            var dictionary = page.dictionary
            if let box = overlay.box {
                // Written onto the page itself even where the original left
                // the box to the page tree to say: a value inherited from the
                // parent would go on applying to every other page too.
                dictionary["MediaBox"] = rectangle(box)
                // The crop box is what a reader actually shows, and a page
                // that declares none takes the media box. Leaving an old one
                // behind would crop the marks back off.
                dictionary["CropBox"] = rectangle(box)
                // The sheet's original extent, kept the way the tablet's own
                // export keeps it: once the media box has grown, nothing else
                // in the file says which part of it is the imported page.
                if let sheet = page.mediaBox { dictionary["ArtBox"] = rectangle(sheet) }
            }
            dictionary["Contents"] = .array(
                [.reference(number: openState, generation: 0)]
                    + (try contentsList(of: page.dictionary["Contents"], in: file))
                    + [
                        .reference(number: closeState, generation: 0),
                        .reference(number: marks, generation: 0),
                    ]
            )
            dictionary["Resources"] = try resources(
                of: page,
                in: file,
                adding: states,
                stencils: stencils
            )
            // The same object number: an incremental update replaces a page by
            // writing it again, and the newest cross-reference wins.
            _ = emit(.dictionary(dictionary), number: page.number)
        }

        let crossReference = offset + body.count
        body.append(crossReferenceTable(newOffsets))
        body.append(trailer(of: file, size: nextNumber, crossReference: crossReference))

        try handle.write(contentsOf: body)
    }

    /// A box the way PDF writes one: lower left corner, then upper right.
    private func rectangle(_ box: CGRect) -> PDFObject {
        .array([.real(box.minX), .real(box.minY), .real(box.maxX), .real(box.maxY)])
    }

    /// A stream object with its length filled in.
    private func stream(_ text: String) -> PDFObject {
        stream(Data(text.utf8))
    }

    private func stream(_ data: Data) -> PDFObject {
        .stream(dictionary: ["Length": .integer(data.count)], data: data)
    }

    /// The same for a stream whose dictionary says more than its length.
    private func stream(_ dictionary: [String: PDFObject], _ data: Data) -> PDFObject {
        var entries = dictionary
        entries["Length"] = .integer(data.count)
        return .stream(dictionary: entries, data: data)
    }

    /// `/Contents` is one stream, an array of them, or a reference to either.
    ///
    /// The reference to an array is the case worth the resolving: wrapped
    /// as-is it would make an array holding an array, which is not a thing
    /// `/Contents` may be, and the page's own drawing would go missing while
    /// our marks stayed. The streams themselves are left as references —
    /// nothing is copied here.
    private func contentsList(of object: PDFObject?, in file: PDFFile) throws -> [PDFObject] {
        guard let object else { return [] }
        if case .array(let items) = object { return items }
        if case .reference = object,
           case .array(let items) = try file.resolve(object) {
            return items
        }
        return [object]
    }

    /// The page's resources with ours added.
    ///
    /// Copied rather than replaced: `/ExtGState` and `/XObject` may already
    /// be there, and putting ours in their place would take away the names
    /// the page's own drawing uses. Inheritance is resolved by the reader,
    /// so a page that declares no resources of its own still gets its
    /// parent's here.
    private func resources(
        of page: PDFFile.Page,
        in file: PDFFile,
        adding extra: [String: PDFObject],
        stencils: [String: PDFObject]
    ) throws -> PDFObject {
        guard !extra.isEmpty || !stencils.isEmpty else { return page.resources ?? .dictionary([:]) }
        var dictionary = try file.resolve(page.resources).dictionaryValue ?? [:]
        if !extra.isEmpty {
            var states = try file.resolve(dictionary["ExtGState"]).dictionaryValue ?? [:]
            for (name, value) in extra { states[name] = value }
            dictionary["ExtGState"] = .dictionary(states)
        }
        if !stencils.isEmpty {
            var objects = try file.resolve(dictionary["XObject"]).dictionaryValue ?? [:]
            for (name, value) in stencils { objects[name] = value }
            dictionary["XObject"] = .dictionary(objects)
        }
        return .dictionary(dictionary)
    }

    /// The new cross-reference section: the objects this update changed,
    /// grouped into runs of consecutive numbers.
    private func crossReferenceTable(_ offsets: [Int: Int]) -> Data {
        var out = Data("xref\n".utf8)
        var numbers = offsets.keys.sorted()
        while !numbers.isEmpty {
            var run = [numbers.removeFirst()]
            while let next = numbers.first, next == run[run.count - 1] + 1 {
                run.append(numbers.removeFirst())
            }
            out.append(contentsOf: Array("\(run[0]) \(run.count)\n".utf8))
            for number in run {
                // Twenty bytes a row, exactly: offset, generation, kind.
                out.append(contentsOf: Array(String(format: "%010d 00000 n \n", offsets[number] ?? 0).utf8))
            }
        }
        return out
    }

    private func trailer(of file: PDFFile, size: Int, crossReference: Int) -> Data {
        var entries: [String: PDFObject] = [
            "Size": .integer(size),
            "Prev": .integer(file.lastCrossReference),
        ]
        // What identifies the document is carried over as it stands: /Root
        // says which catalogue to read, /Info and /ID are what the file says
        // about itself, and rewriting either would be a change we did not mean
        // to make.
        for key in ["Root", "Info", "ID"] {
            if let value = file.trailer[key] { entries[key] = value }
        }
        var out = Data("trailer\n".utf8)
        PDFWriter.append(.dictionary(entries), to: &out)
        out.append(contentsOf: Array("\nstartxref\n\(crossReference)\n%%EOF\n".utf8))
        return out
    }
}
