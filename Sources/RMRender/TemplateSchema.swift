// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines

/// A value in a template: either a number or an expression as a string
/// (`"templateWidth / 2"`). The format mixes them freely, so there is one
/// type for both.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum TemplateValue: Sendable, Hashable {
    case number(Double)
    case expression(String)
}

extension TemplateValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .expression(try container.decode(String.self))
        }
    }
}

/// An item's rectangle. Any side may be an expression.
public struct TemplateBox: Decodable, Sendable, Hashable {
    public let x: TemplateValue?
    public let y: TemplateValue?
    public let width: TemplateValue?
    public let height: TemplateValue?
}

/// How to repeat a group. The string is either a direction (`down`, `up`,
/// `right`, `infinite`) or an expression giving a count.
public struct TemplateRepeat: Decodable, Sendable, Hashable {
    public let rows: TemplateValue?
    public let columns: TemplateValue?
}

/// A path token: a command (`M`, `L`, `C`, `Z`) or a coordinate.
///
/// Frozen: this framework ships in lockstep with what links it, so there is
/// no ABI to protect — and an exhaustive `switch` over these cases in a
/// consumer is the point. A new case must break its build, not fall into an
/// `@unknown default`.
@frozen
public enum TemplatePathToken: Sendable, Hashable {
    case command(String)
    case value(TemplateValue)

    /// The letters SVG gives a path, in both cases. Only these count as
    /// commands; any other single letter is a name to be looked up.
    ///
    /// The set matters because a coordinate may be a bare constant, and a
    /// template is free to call one `w`. Treating every letter as a command
    /// would swallow such a coordinate whole — a template may declare
    /// constants `h` and `w` and is safe only while it uses them inside longer
    /// expressions. `h` stays ambiguous, and nothing at this layer
    /// can settle it: the token is decoded on its own, without the constants
    /// to check it against. The ambiguity is not silent, though — `buildPath`
    /// draws none of `H`, so a swallowed `h` reaches the log.
    static let commandLetters: Set<Character> = [
        "M", "L", "H", "V", "C", "S", "Q", "T", "A", "Z",
        "m", "l", "h", "v", "c", "s", "q", "t", "a", "z",
    ]
}

extension TemplatePathToken: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .value(.number(number))
            return
        }
        let text = try container.decode(String.self)
        // Single-character SVG letters are commands; everything else is an
        // expression. The case is kept: a lowercase command counts from the
        // previous point rather than from the origin, and upper-casing it
        // would turn a relative command into an absolute one. Templates
        // rarely use one, so such a mistake would go unseen until one did.
        if text.count == 1, let letter = text.first, Self.commandLetters.contains(letter) {
            self = .command(text)
        } else {
            self = .value(.expression(text))
        }
    }
}

/// A node of a template.
public indirect enum TemplateItem: Sendable, Hashable {
    case group(Group)
    case path(Path)
    case text(Text)

    public struct Group: Decodable, Sendable, Hashable {
        public let boundingBox: TemplateBox?
        public let `repeat`: TemplateRepeat?
        public let children: [TemplateItem]
    }

    public struct Path: Decodable, Sendable, Hashable {
        public let data: [TemplatePathToken]
        public let strokeWidth: TemplateValue?
        let strokeColor: String?
        let fillColor: String?
    }

    public struct Text: Decodable, Sendable, Hashable {
        public let text: String
        public let fontSize: TemplateValue?
        public let position: TemplateBox?
    }
}

extension TemplateItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
        switch type {
        case "group": self = .group(try Group(from: decoder))
        case "path": self = .path(try Path(from: decoder))
        case "text": self = .text(try Text(from: decoder))
        default:
            throw RenderError.unsupportedFormat("unknown template item: \(type)")
        }
    }
}

/// A parsed page template.
public struct Template: Decodable, Sendable, Hashable {
    public let name: String
    public let orientation: String?
    /// The shelves the tablet files it under — `Lines`, `Grids`,
    /// `Creative`, `Planners`. A host that offers a template to write on
    /// picks its shelves by these.
    public let categories: [String]?
    /// An array of single-pair dictionaries: the order matters, since the
    /// next constant may refer to the previous one.
    public let constants: [[String: TemplateValue]]?
    public let items: [TemplateItem]

    public var isLandscape: Bool { orientation == "landscape" }
}
