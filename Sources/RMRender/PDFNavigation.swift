// Copyright 2026 ALTESSA SOLUTIONS INC. MIT license.
import CoreGraphics
import Foundation
import PDFKit

/// Navigation is emitted into the fresh context, without rewriting its page contents.
struct PDFNavigation {
    struct Link {
        let box: CGRect
        let url: URL?
        let name: String?
    }
    var links: [Int: [Link]] = [:]
    var destinations: [Int: [(String, CGPoint)]] = [:]
    var outline: [String: Any]?

    init(original: URL, document: CGPDFDocument, mapping: [(source: Int?, visible: Bool, sheet: CGSize)]) throws {
        guard let source = PDFDocument(url: original) else { throw RenderError.malformedPage("navigation PDF does not open") }
        var indices: [Int: Int] = [:]
        for (index, item) in mapping.enumerated() {
            if let number = item.source, indices[number] == nil { indices[number] = index }
        }
        func transform(_ sourceIndex: Int, _ outputIndex: Int) -> CGAffineTransform? {
            guard let page = document.page(at: sourceIndex + 1) else { return nil }
            return AnnotatedPDFRenderer.sourceTransform(page, onto: CGRect(origin: .zero, size: mapping[outputIndex].sheet))
        }
        var work = 0
        for (index, item) in mapping.enumerated() where item.visible {
            guard let number = item.source, let page = source.page(at: number),
                  let placement = transform(number, index) else { continue }
            for old in page.annotations where old.type == "Link" {
                work += 1
                guard work <= 1_000_000 else { throw PDFReadError.malformed("navigation limit") }
                let box = old.bounds.applying(placement)
                if let action = old.action as? PDFActionURL, let url = action.url {
                    links[index, default: []].append(Link(box: box, url: url, name: nil))
                } else if let destination = (old.action as? PDFActionGoTo)?.destination ?? old.destination,
                          let page = destination.page,
                          let target = indices[source.index(for: page)],
                          let targetTransform = transform(source.index(for: page), target) {
                    let name = "RMNavigation\(work)"
                    var point = destination.point
                    // The target page's box fills in a coordinate the
                    // destination leaves open; the link keeps its own `box`.
                    let targetBox = page.bounds(for: .mediaBox)
                    if !point.x.isFinite || point.x == .greatestFiniteMagnitude { point.x = targetBox.minX }
                    if !point.y.isFinite || point.y == .greatestFiniteMagnitude { point.y = targetBox.maxY }
                    destinations[target, default: []].append((name, point.applying(targetTransform)))
                    links[index, default: []].append(Link(box: box, url: nil, name: name))
                }
            }
        }
        func children(_ input: Any?, depth: Int) throws -> [[String: Any]] {
            guard depth < 128 else { throw PDFReadError.malformed("outline depth") }
            guard let input = input as? [[String: Any]] else { return [] }
            var output: [[String: Any]] = []
            for var item in input {
                work += 1
                guard work <= 1_000_000 else { throw PDFReadError.malformed("navigation limit") }
                let nested = try children(item[kCGPDFOutlineChildren as String], depth: depth + 1)
                let destination = item[kCGPDFOutlineDestination as String]
                if let number = destination as? NSNumber, let index = indices[number.intValue - 1] {
                    item[kCGPDFOutlineDestination as String] = index + 1
                    if let raw = item[kCGPDFOutlineDestinationRect as String] as? NSDictionary,
                       let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                       let placement = transform(number.intValue - 1, index) {
                        item[kCGPDFOutlineDestinationRect as String] = rect.applying(placement).dictionaryRepresentation
                    }
                } else if !(destination is URL) {
                    output.append(contentsOf: nested)
                    continue
                }
                item[kCGPDFOutlineChildren as String] = nested.isEmpty ? nil : nested
                output.append(item)
            }
            return output
        }
        if let originalOutline = document.outline as? [String: Any] {
            outline = [kCGPDFOutlineChildren as String: try children(originalOutline[kCGPDFOutlineChildren as String], depth: 0)]
        }
    }

    func draw(page: Int, in context: CGContext) {
        for (name, point) in destinations[page] ?? [] { context.addDestination(name as CFString, at: point) }
        for link in links[page] ?? [] {
            if let url = link.url { context.setURL(url as CFURL, for: link.box) }
            if let name = link.name { context.setDestination(name as CFString, for: link.box) }
        }
    }

    func finish(in context: CGContext) {
        if let outline { CGPDFContextSetOutline(context, outline as CFDictionary) }
    }
}
