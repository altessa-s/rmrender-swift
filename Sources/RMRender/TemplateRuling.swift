// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import CoreGraphics
import Foundation
import RMMarks

/// A template a hand can be written along: the name a page declares, the
/// name a reader is shown, and its ruling — measured off a drawing of it
/// rather than read out of the description, since two templates that rule a
/// page the same way say so very differently, one repeating a box downwards
/// and another tiling a cell over the sheet.
public struct RuledTemplate: Sendable, Hashable, Identifiable {
    /// The file's name — what `.content` and `.pagedata` carry.
    public let name: String
    /// The template's own name for itself, as a reader is shown it.
    public let title: String
    public let ruling: Ruling

    public var id: String { name }
}

extension TemplateStore {
    /// The shelves a template must be filed under to be offered as paper to
    /// write on. A perspective guide and a bass tab are ruled as evenly as a
    /// pad, and neither is a page anybody writes a letter on.
    private static let writableCategories: Set<String> = ["Lines", "Grids"]

    /// The upright templates of those shelves whose lines run evenly down
    /// the whole page — the ones a line of writing can be laid along. A
    /// template ruled over half its page, a planner, a storyboard and a
    /// staff are left out by the measurement rather than by a list of
    /// names.
    public func ruledTemplates(pageSize: CGSize) -> [RuledTemplate] {
        ruled.withLock { cache in
            let key = Self.key(pageSize)
            if let known = cache[key] { return known }
            let found = availableNames().compactMap { name -> RuledTemplate? in
                guard let template = template(named: name), !template.isLandscape,
                      let shelves = template.categories,
                      !Self.writableCategories.isDisjoint(with: shelves),
                      let ruling = ruling(named: name, pageSize: pageSize)
                else { return nil }
                return RuledTemplate(name: name, title: template.name, ruling: ruling)
            }
            .sorted { ($0.ruling.pitch, $0.title) < ($1.ruling.pitch, $1.title) }
            cache[key] = found
            return found
        }
    }

    /// The ruling of one template, or nothing where its lines do not run
    /// evenly down the page.
    public func ruling(named name: String, pageSize: CGSize) -> Ruling? {
        let key = "\(name)|\(Self.key(pageSize))"
        if let known = rulings.withLock({ $0[key] }) { return known }
        let measured = template(named: name).flatMap { TemplateScan.ruling(of: $0, pageSize: pageSize) }
        rulings.withLock { $0[key] = measured }
        return measured
    }

    private static func key(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }
}
