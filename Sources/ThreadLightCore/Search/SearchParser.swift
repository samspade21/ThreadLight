import Foundation

public indirect enum SearchExpression: Equatable, Sendable {
    case term(String, field: SearchField?)
    case phrase(String, field: SearchField?)
    case and(SearchExpression, SearchExpression)
    case or(SearchExpression, SearchExpression)
    case not(SearchExpression)
    case near(SearchExpression, SearchExpression, distance: Int)

    public func fts5() -> String {
        switch self {
        case let .term(value, field):
            return fieldPrefix(field) + quoted(value)
        case let .phrase(value, field):
            return fieldPrefix(field) + quoted(value)
        case let .and(lhs, rhs): return "(\(lhs.fts5()) AND \(rhs.fts5()))"
        case let .or(lhs, rhs): return "(\(lhs.fts5()) OR \(rhs.fts5()))"
        case let .not(value): return "NOT (\(value.fts5()))"
        case let .near(lhs, rhs, distance): return "NEAR(\(lhs.fts5()) \(rhs.fts5()), \(min(max(distance, 1), 50)))"
        }
    }

    private func fieldPrefix(_ field: SearchField?) -> String {
        guard let field else { return "" }
        return "\(field.ftsColumn):"
    }

    private func quoted(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(clean)\""
    }
}

public enum SearchField: String, CaseIterable, Equatable, Sendable {
    case text
    case from
    case `in`
    case file

    var ftsColumn: String {
        switch self {
        case .text: "text"
        case .from: "sender_name"
        case .in: "conversation_name"
        case .file: "file_text"
        }
    }
}

public struct ParsedSearch: Equatable, Sendable {
    public var expression: SearchExpression?
    public var filters: SearchFilters
    public var warnings: [String]

    public var fts5Expression: String? { expression?.fts5() }
}

public enum SearchParser {
    public static func parse(_ query: SearchQuery, calendar: Calendar = .current) throws -> ParsedSearch {
        switch query.mode {
        case .basic: return parseBasic(query, calendar: calendar)
        case .advanced:
            var lexer = Lexer(query.text)
            let tokens = try lexer.tokens()
            var parser = AdvancedParser(tokens: tokens)
            return .init(expression: try parser.parse(), filters: query.filters, warnings: [])
        }
    }

    private static func parseBasic(_ query: SearchQuery, calendar: Calendar) -> ParsedSearch {
        var filters = query.filters
        var expressions: [SearchExpression] = []
        var warnings: [String] = []

        for part in BasicTokenizer.tokenize(query.text) {
            let raw = part.value
            if let separator = raw.firstIndex(of: ":") {
                let key = String(raw[..<separator]).lowercased()
                let value = String(raw[raw.index(after: separator)...])
                switch key {
                case "from": filters.sender = value
                case "in": filters.conversation = value
                case "after":
                    if let date = parseDate(value, calendar: calendar) { filters.after = date }
                    else { warnings.append("Ignored invalid after date: \(value)") }
                case "before":
                    if let date = parseDate(value, calendar: calendar) { filters.before = date }
                    else { warnings.append("Ignored invalid before date: \(value)") }
                case "has" where value.lowercased() == "file": filters.hasAttachment = true
                case "is" where value.lowercased() == "thread": filters.isThread = true
                case "is" where value.lowercased() == "edited": filters.isEdited = true
                case "is" where value.lowercased() == "deleted": filters.isDeleted = true
                case "filetype": filters.fileType = value.lowercased()
                default: expressions.append(.term(raw, field: nil))
                }
            } else if part.quoted {
                expressions.append(.phrase(raw, field: nil))
            } else if !raw.isEmpty {
                expressions.append(.term(raw, field: nil))
            }
        }
        return .init(expression: expressions.reduce(nil) { current, next in current.map { .and($0, next) } ?? next }, filters: filters, warnings: warnings)
    }

    private static func parseDate(_ value: String, calendar: Calendar) -> Date? {
        if let date = try? Date(value, strategy: .iso8601.year().month().day()) { return date }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .init(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.date(from: value)
    }
}

private enum BasicTokenizer {
    struct Part { let value: String; let quoted: Bool }

    static func tokenize(_ text: String) -> [Part] {
        var result: [Part] = []
        var buffer = ""
        var quoted = false
        var wasQuoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                wasQuoted = true
            } else if character.isWhitespace && !quoted {
                if !buffer.isEmpty { result.append(.init(value: buffer, quoted: wasQuoted)); buffer = ""; wasQuoted = false }
            } else {
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { result.append(.init(value: buffer, quoted: wasQuoted)) }
        return result
    }
}

private enum SearchToken: Equatable {
    case word(String)
    case phrase(String)
    case fieldPhrase(SearchField, String)
    case and
    case or
    case not
    case near(Int)
    case leftParen
    case rightParen
}

private struct Lexer {
    private let input: [Character]
    private var index = 0

    init(_ input: String) { self.input = Array(input) }

    mutating func tokens() throws -> [SearchToken] {
        var result: [SearchToken] = []
        while index < input.count {
            if input[index].isWhitespace { index += 1; continue }
            if input[index] == "(" { result.append(.leftParen); index += 1; continue }
            if input[index] == ")" { result.append(.rightParen); index += 1; continue }
            if input[index] == "\"" {
                index += 1
                var value = ""
                while index < input.count, input[index] != "\"" { value.append(input[index]); index += 1 }
                guard index < input.count else { throw ThreadLightError.invalidConfiguration("Search phrase is missing a closing quote.") }
                index += 1
                result.append(.phrase(value))
                continue
            }
            var value = ""
            while index < input.count,
                  !input[index].isWhitespace,
                  input[index] != "(",
                  input[index] != ")",
                  input[index] != "\"" {
                value.append(input[index]); index += 1
            }
            if index < input.count,
               input[index] == "\"",
               value.hasSuffix(":"),
               let field = SearchField(rawValue: String(value.dropLast()).lowercased()) {
                index += 1
                var phrase = ""
                while index < input.count, input[index] != "\"" { phrase.append(input[index]); index += 1 }
                guard index < input.count else { throw ThreadLightError.invalidConfiguration("Search phrase is missing a closing quote.") }
                index += 1
                result.append(.fieldPhrase(field, phrase))
                continue
            }
            switch value.uppercased() {
            case "AND": result.append(.and)
            case "OR": result.append(.or)
            case "NOT": result.append(.not)
            default:
                if value.uppercased().hasPrefix("NEAR/") {
                    guard let distance = Int(value.dropFirst(5)), (1...50).contains(distance) else {
                        throw ThreadLightError.invalidConfiguration("NEAR distance must be between 1 and 50.")
                    }
                    result.append(.near(distance))
                } else {
                    result.append(.word(value))
                }
            }
        }
        return result
    }
}

private struct AdvancedParser {
    let tokens: [SearchToken]
    var index = 0

    mutating func parse() throws -> SearchExpression? {
        guard !tokens.isEmpty else { return nil }
        let expression = try parseOr()
        guard index == tokens.count else { throw ThreadLightError.invalidConfiguration("Unexpected search token near the end of the query.") }
        return expression
    }

    private mutating func parseOr() throws -> SearchExpression {
        var lhs = try parseAnd()
        while consume(.or) { lhs = .or(lhs, try parseAnd()) }
        return lhs
    }

    private mutating func parseAnd() throws -> SearchExpression {
        var lhs = try parseNear()
        while true {
            if consume(.and) {
                lhs = .and(lhs, try parseNear())
            } else if index < tokens.count, startsPrimary(tokens[index]) {
                lhs = .and(lhs, try parseNear())
            } else { break }
        }
        return lhs
    }

    private mutating func parseNear() throws -> SearchExpression {
        var lhs = try parseUnary()
        if index < tokens.count, case let .near(distance) = tokens[index] {
            index += 1
            let rhs = try parseUnary()
            guard lhs.isProximityOperand, rhs.isProximityOperand else {
                throw ThreadLightError.invalidConfiguration("NEAR works between two terms or quoted phrases. Put Boolean groups outside the proximity expression.")
            }
            lhs = .near(lhs, rhs, distance: distance)
        }
        return lhs
    }

    private mutating func parseUnary() throws -> SearchExpression {
        if consume(.not) { return .not(try parseUnary()) }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> SearchExpression {
        guard index < tokens.count else { throw ThreadLightError.invalidConfiguration("Search query ends unexpectedly.") }
        let token = tokens[index]
        index += 1
        switch token {
        case let .word(value): return fielded(value, phrase: false)
        case let .phrase(value): return .phrase(value, field: nil)
        case let .fieldPhrase(field, value): return .phrase(value, field: field)
        case .leftParen:
            let expression = try parseOr()
            guard consume(.rightParen) else { throw ThreadLightError.invalidConfiguration("Search group is missing a closing parenthesis.") }
            return expression
        default: throw ThreadLightError.invalidConfiguration("Expected a search term or phrase.")
        }
    }

    private func fielded(_ value: String, phrase: Bool) -> SearchExpression {
        guard let separator = value.firstIndex(of: ":"),
              let field = SearchField(rawValue: String(value[..<separator]).lowercased()) else {
            return phrase ? .phrase(value, field: nil) : .term(value, field: nil)
        }
        let term = String(value[value.index(after: separator)...])
        return phrase ? .phrase(term, field: field) : .term(term, field: field)
    }

    private mutating func consume(_ token: SearchToken) -> Bool {
        guard index < tokens.count, tokens[index] == token else { return false }
        index += 1
        return true
    }

    private func startsPrimary(_ token: SearchToken) -> Bool {
        switch token { case .word, .phrase, .fieldPhrase, .leftParen, .not: true; default: false }
    }
}

private extension SearchExpression {
    var isProximityOperand: Bool {
        switch self {
        case .term, .phrase: true
        case .and, .or, .not, .near: false
        }
    }
}
