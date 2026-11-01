// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks

/// Reads a template's ruling off a drawing of it.
///
/// A rule is a row of the page inked far beyond what the page is inked
/// anywhere else: a line inks every pixel across, a row of dots inks a score
/// of them, and a grid's verticals ink two dozen in every row there is — so
/// the bar is set against the page's own middling row rather than at a fixed
/// count, and all three answer correctly.
enum TemplateScan {
    /// How many rules make a ruling, how evenly they must run, and how much
    /// of the page they must cover. A template ruled over half its height is
    /// a template to draw on, not one to write along.
    private static let fewestRules = 5
    private static let evenness = 2.0
    private static let coverage = 0.75
    private static let topmost = 0.35

    static func ruling(of template: Template, pageSize: CGSize) -> Ruling? {
        guard !template.isLandscape,
              let page = drawn(template, pageSize: pageSize)
        else { return nil }
        let rules = lines(along: page.rows)
        guard rules.count >= fewestRules, let first = rules.first, let last = rules.last else { return nil }
        // Over the whole run rather than between two neighbours: a rule is
        // measured to the half-pixel, and a step taken from one pair carries
        // that error into every line down the page, where the span divides
        // it by the number of rules.
        let pitch = (last - first) / Double(rules.count - 1)
        let steps = zip(rules, rules.dropFirst()).map { $1 - $0 }
        guard steps.allSatisfy({ abs($0 - pitch) <= evenness }),
              first <= Double(page.height) * topmost,
              last - first >= Double(page.height) * coverage
        else { return nil }
        return Ruling(first: first, pitch: pitch, leftMargin: margin(of: page))
    }

    /// One inked count per row and one per column, off a drawing of the
    /// template at the page's own size.
    private struct Drawing {
        let rows: [Int]
        let columns: [Int]
        var width: Int { columns.count }
        var height: Int { rows.count }
    }

    private static func drawn(_ template: Template, pageSize: CGSize) -> Drawing? {
        let width = Int(pageSize.width.rounded()), height = Int(pageSize.height.rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        TemplateRenderer.draw(template, in: context, size: CGSize(width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var rows = [Int](repeating: 0, count: height)
        var columns = [Int](repeating: 0, count: width)
        for row in 0..<height {
            let line = row * width
            for column in 0..<width where pixels[line + column] < 250 {
                rows[row] += 1
                columns[column] += 1
            }
        }
        return Drawing(rows: rows, columns: columns)
    }

    /// The middles of the runs of rows inked past the bar. A drawn line
    /// covers two rows where it falls between them, so a rule is a run and
    /// not a row.
    private static func lines(along counts: [Int]) -> [Double] {
        let bar = self.bar(for: counts)
        var lines: [Double] = []
        var run: [Int] = []
        for (index, count) in counts.enumerated() where count >= bar {
            if let last = run.last, index > last + 1 {
                lines.append(Double(run[0] + run[run.count - 1]) / 2)
                run = []
            }
            run.append(index)
        }
        if !run.isEmpty { lines.append(Double(run[0] + run[run.count - 1]) / 2) }
        return lines
    }

    /// Well past the page's middling row and never under a handful of
    /// pixels: the first keeps a grid's verticals from counting as rules,
    /// the second keeps an empty page from ruling itself out of noise.
    private static func bar(for counts: [Int]) -> Int {
        let middling = counts.sorted()[counts.count / 2]
        return max(8, 5 * middling)
    }

    /// The one full-height line a margin draws, where there is one. A grid
    /// rules its verticals as evenly as its rows, and a page ruled that way
    /// has no margin to write after.
    private static func margin(of page: Drawing) -> Double? {
        let verticals = lines(along: page.columns)
        guard verticals.count <= 2, let leftmost = verticals.first,
              leftmost <= Double(page.width) * 0.45
        else { return nil }
        return leftmost
    }
}
