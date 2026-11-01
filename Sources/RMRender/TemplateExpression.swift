// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation
import RMLines
import Synchronization

/// The evaluator for template expressions.
///
/// The files hold more than arithmetic:
/// `"templateWidth < mobileMaxWidth || templateHeight < mobileMaxWidth
///   ? mobileOffsetY : magicOffsetY"`.
/// Hence a parser with precedence rather than substituting numbers. Boolean
/// values are 1 and 0, as in the original format.
struct TemplateExpression: Sendable {
    private let tokens: [Token]

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(String)
    }

    public init(_ source: String) throws {
        tokens = try Self.tokenize(source)
    }

    /// The expression of a source string, tokenized once.
    ///
    /// A template's expressions are the same handful of strings evaluated
    /// once per cell of a grid, so without this the tokenizer would run
    /// thousands of times over the same few characters. The store is bounded and dropped whole when
    /// it fills: the set of strings in the templates is small, and a page
    /// that somehow brings its own is not worth growing memory for.
    static func compiled(_ source: String) throws -> TemplateExpression {
        if let cached = store.withLock({ $0[source] }) { return cached }
        let expression = try TemplateExpression(source)
        store.withLock { compiled in
            if compiled.count >= storeCeiling { compiled.removeAll(keepingCapacity: true) }
            compiled[source] = expression
        }
        return expression
    }

    private static let store = Mutex<[String: TemplateExpression]>([:])
    private static let storeCeiling = 512

    /// The value of the expression in a given environment.
    public func value(in environment: [String: Double]) throws -> Double {
        var parser = Parser(tokens: tokens, environment: environment)
        let result = try parser.parseTernary()
        guard parser.isAtEnd else {
            throw RenderError.malformedPage("expression not fully parsed")
        }
        return result
    }

    // MARK: - Tokenizing

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
            } else if character.isNumber || character == "." {
                var text = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    text.append(characters[index])
                    index += 1
                }
                guard let number = Double(text) else {
                    throw RenderError.malformedPage("not a number: \(text)")
                }
                tokens.append(.number(number))
            } else if character.isLetter || character == "_" {
                var text = ""
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    text.append(characters[index])
                    index += 1
                }
                tokens.append(.identifier(text))
            } else {
                // Two-character operators come first, otherwise "<=" becomes
                // "<".
                let pair = index + 1 < characters.count ? String([character, characters[index + 1]]) : ""
                if ["||", "&&", "<=", ">=", "==", "!="].contains(pair) {
                    tokens.append(.symbol(pair))
                    index += 2
                } else {
                    tokens.append(.symbol(String(character)))
                    index += 1
                }
            }
        }
        return tokens
    }

    // MARK: - Parsing the expression

    private struct Parser {
        let tokens: [Token]
        let environment: [String: Double]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }

        private mutating func match(_ symbol: String) -> Bool {
            guard position < tokens.count, tokens[position] == .symbol(symbol) else { return false }
            position += 1
            return true
        }

        mutating func parseTernary() throws -> Double {
            let condition = try parseOr()
            guard match("?") else { return condition }

            let whenTrue = try parseTernary()
            guard match(":") else {
                throw RenderError.malformedPage("ternary operator without a colon")
            }
            let whenFalse = try parseTernary()
            return condition != 0 ? whenTrue : whenFalse
        }

        private mutating func parseOr() throws -> Double {
            var left = try parseAnd()
            while match("||") {
                let right = try parseAnd()
                left = (left != 0 || right != 0) ? 1 : 0
            }
            return left
        }

        private mutating func parseAnd() throws -> Double {
            var left = try parseComparison()
            while match("&&") {
                let right = try parseComparison()
                left = (left != 0 && right != 0) ? 1 : 0
            }
            return left
        }

        private mutating func parseComparison() throws -> Double {
            let left = try parseAdditive()
            for symbol in ["<=", ">=", "==", "!=", "<", ">"] where match(symbol) {
                let right = try parseAdditive()
                switch symbol {
                case "<=": return left <= right ? 1 : 0
                case ">=": return left >= right ? 1 : 0
                case "==": return left == right ? 1 : 0
                case "!=": return left != right ? 1 : 0
                case "<": return left < right ? 1 : 0
                default: return left > right ? 1 : 0
                }
            }
            return left
        }

        private mutating func parseAdditive() throws -> Double {
            var left = try parseMultiplicative()
            while true {
                if match("+") {
                    left += try parseMultiplicative()
                } else if match("-") {
                    left -= try parseMultiplicative()
                } else {
                    return left
                }
            }
        }

        private mutating func parseMultiplicative() throws -> Double {
            var left = try parseUnary()
            while true {
                if match("*") {
                    left *= try parseUnary()
                } else if match("/") {
                    let divisor = try parseUnary()
                    // Division by zero in a template is no reason to bring
                    // the page down.
                    left = divisor == 0 ? 0 : left / divisor
                } else {
                    return left
                }
            }
        }

        private mutating func parseUnary() throws -> Double {
            if match("-") { return -(try parseUnary()) }
            if match("+") { return try parseUnary() }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Double {
            guard position < tokens.count else {
                throw RenderError.malformedPage("expression ended unexpectedly")
            }

            if match("(") {
                let value = try parseTernary()
                guard match(")") else {
                    throw RenderError.malformedPage("unclosed parenthesis")
                }
                return value
            }

            switch tokens[position] {
            case .number(let value):
                position += 1
                return value
            case .identifier(let name):
                position += 1
                guard let value = environment[name] else {
                    throw RenderError.malformedPage("unknown name: \(name)")
                }
                return value
            case .symbol(let symbol):
                throw RenderError.malformedPage("unexpected symbol: \(symbol)")
            }
        }
    }
}

extension TemplateValue {
    /// The number in a given environment.
    public func resolved(in environment: [String: Double]) throws -> Double {
        switch self {
        case .number(let value): value
        case .expression(let source): try TemplateExpression.compiled(source).value(in: environment)
        }
    }
}
