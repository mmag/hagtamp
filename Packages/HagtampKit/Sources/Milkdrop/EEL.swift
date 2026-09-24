import Foundation

/// Variables of one code block (per-frame, per-vertex, a wave or a shape),
/// by name, case-insensitive. Unknown names start at 0.
public final class EELVariables: @unchecked Sendable {
    public private(set) var names: [String: Int] = [:]
    var values: [Double] = []
    /// megabuf(i): memory local to the block; gmegabuf(i) is shared by all blocks.
    var megabuf: [Double] = []
    let global: EELGlobalMemory

    public init(global: EELGlobalMemory = EELGlobalMemory()) {
        self.global = global
    }

    public func slot(_ name: String) -> Int {
        let key = name.lowercased()
        if let index = names[key] { return index }
        names[key] = values.count
        values.append(0)
        return values.count - 1
    }

    public subscript(name: String) -> Double {
        get { names[name.lowercased()].map { values[$0] } ?? 0 }
        set { values[slot(name)] = newValue }
    }

    public subscript(slot: Int) -> Double {
        get { values[slot] }
        set { values[slot] = newValue }
    }
}

/// gmegabuf: memory every block of a preset shares.
public final class EELGlobalMemory: @unchecked Sendable {
    var cells: [Double] = []
    public init() {}
}

public struct EELError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// A compiled block of preset code. MilkDrop's expression language (NS-EEL,
/// with the EEL2 additions MilkDrop 2 presets use): statements separated by
/// ";", assignments (= += -= *= /= %=), + - * / % ^, comparisons, && || !,
/// ?:, (a; b) sequences and the usual functions (sin, pow, if, above,
/// megabuf, loop...). Division by zero gives 0, like the original.
public struct EELProgram: @unchecked Sendable {
    public let source: String
    private let body: (EELVariables) -> Double
    public let isEmpty: Bool

    public init(_ source: String, variables: EELVariables) throws {
        self.source = source
        var parser = EELParser(tokens: try EELLexer.tokens(of: source))
        let node = try parser.program()
        isEmpty = node == nil
        body = node.map { EELCompiler(variables: variables).compile($0) } ?? { _ in 0 }
    }

    /// Runs the block; returns the value of its last statement.
    @discardableResult
    public func run(_ variables: EELVariables) -> Double {
        body(variables)
    }
}

// MARK: - Lexer

enum EELToken: Equatable {
    case number(Double)
    case name(String)
    case op(String)
}

enum EELLexer {
    static let operators = ["+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "%", "^", "=", "<", ">", "!", "?", ":", "(", ")", ",", ";", "&", "|"]

    static func tokens(of source: String) throws -> [EELToken] {
        let chars = Array(source)
        var tokens: [EELToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, !chars[i].isNewline { i += 1 }
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                let start = i
                while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
                if i < chars.count, chars[i] == "e" || chars[i] == "E",
                    i + 1 < chars.count, chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber)
                {
                    i += 2
                    while i < chars.count, chars[i].isNumber { i += 1 }
                }
                tokens.append(.number(Double(String(chars[start..<i])) ?? 0))
            } else if c.isLetter || c == "_" || c == "$" {
                let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." || chars[i] == "$" { i += 1 }
                let word = String(chars[start..<i]).lowercased()
                switch word {
                case "$pi": tokens.append(.number(.pi))
                case "$e": tokens.append(.number(M_E))
                case "$phi": tokens.append(.number(1.618033988749894))
                default: tokens.append(.name(word))
                }
            } else if let op = operators.first(where: { op in
                i + op.count <= chars.count && String(chars[i..<i + op.count]) == op
            }) {
                tokens.append(.op(op))
                i += op.count
            } else {
                throw EELError(message: "Unexpected character “\(c)”")
            }
        }
        return tokens
    }
}

// MARK: - Parser

indirect enum EELNode: Equatable {
    case number(Double)
    case variable(String)
    case assign(target: EELNode, op: String, value: EELNode)
    case unary(String, EELNode)
    case binary(String, EELNode, EELNode)
    case ternary(EELNode, EELNode, EELNode)
    case call(String, [EELNode])
    case sequence([EELNode])
}

struct EELParser {
    let tokens: [EELToken]
    var index = 0

    init(tokens: [EELToken]) {
        self.tokens = tokens
    }

    private var current: EELToken? { index < tokens.count ? tokens[index] : nil }

    private mutating func accept(_ op: String) -> Bool {
        if current == .op(op) {
            index += 1
            return true
        }
        return false
    }

    private mutating func expect(_ op: String) throws {
        guard accept(op) else { throw EELError(message: "Expected “\(op)”") }
    }

    /// Statements; nil for nothing but separators.
    mutating func program() throws -> EELNode? {
        var statements: [EELNode] = []
        while current != nil {
            if accept(";") { continue }
            statements.append(try expression())
            if current != nil, !accept(";") {
                throw EELError(message: "Expected “;” between statements")
            }
        }
        return statements.isEmpty ? nil : statements.count == 1 ? statements[0] : .sequence(statements)
    }

    mutating func expression() throws -> EELNode {
        let left = try ternary()
        for op in ["=", "+=", "-=", "*=", "/=", "%="] where accept(op) {
            switch left {
            case .variable, .call("megabuf", _), .call("gmegabuf", _):
                return .assign(target: left, op: op, value: try expression())
            default:
                throw EELError(message: "Can't assign to that")
            }
        }
        return left
    }

    mutating func ternary() throws -> EELNode {
        let condition = try binary(0)
        guard accept("?") else { return condition }
        let yes = try expression()
        try expect(":")
        return .ternary(condition, yes, try expression())
    }

    /// Precedence climbing, loosest first.
    static let levels: [[String]] = [["||"], ["&&"], ["|"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["+", "-"], ["*", "/", "%"]]

    mutating func binary(_ level: Int) throws -> EELNode {
        guard level < Self.levels.count else { return try unary() }
        var left = try binary(level + 1)
        while let op = Self.levels[level].first(where: { current == .op($0) }) {
            index += 1
            left = .binary(op, left, try binary(level + 1))
        }
        return left
    }

    mutating func unary() throws -> EELNode {
        for op in ["-", "+", "!"] where accept(op) {
            return .unary(op, try unary())
        }
        let base = try primary()
        if accept("^") { return .binary("^", base, try unary()) }
        return base
    }

    mutating func primary() throws -> EELNode {
        switch current {
        case .number(let value)?:
            index += 1
            return .number(value)
        case .name(let name)?:
            index += 1
            guard accept("(") else { return .variable(name) }
            var arguments: [EELNode] = []
            if !accept(")") {
                repeat { arguments.append(try sequenceOrExpression(until: [",", ")"])) } while accept(",")
                try expect(")")
            }
            return .call(name, arguments)
        case .op("(")?:
            index += 1
            let node = try sequenceOrExpression(until: [")"])
            try expect(")")
            return node
        default:
            throw EELError(message: current == nil ? "Unexpected end of code" : "Unexpected “\(current!)”")
        }
    }

    /// "(a; b; c)" is a sequence worth its last value (also inside call arguments).
    mutating func sequenceOrExpression(until closers: [String]) throws -> EELNode {
        var items = [try expression()]
        while accept(";") {
            if let current, closers.contains(where: { current == .op($0) }) { break }
            items.append(try expression())
        }
        return items.count == 1 ? items[0] : .sequence(items)
    }
}

// MARK: - Compiler

struct EELCompiler {
    typealias Eval = (EELVariables) -> Double
    let variables: EELVariables

    /// EEL compares with a small tolerance.
    static let epsilon = 0.00001
    /// Loops stop here even if the code says otherwise.
    static let maxIterations = 1_048_576

    func compile(_ node: EELNode) -> Eval {
        switch node {
        case .number(let value):
            return { _ in value }
        case .variable(let name):
            let slot = variables.slot(name)
            return { $0.values[slot] }
        case .sequence(let items):
            let compiled = items.map(compile)
            return { vars in
                var last = 0.0
                for item in compiled { last = item(vars) }
                return last
            }
        case .assign(let target, let op, let valueNode):
            return assignment(target, op, compile(valueNode))
        case .unary(let op, let operand):
            let a = compile(operand)
            switch op {
            case "-": return { -a($0) }
            case "!": return { abs(a($0)) < Self.epsilon ? 1 : 0 }
            default: return a
            }
        case .binary(let op, let l, let r):
            return binary(op, compile(l), compile(r))
        case .ternary(let c, let y, let n):
            let condition = compile(c), yes = compile(y), no = compile(n)
            return { abs(condition($0)) >= Self.epsilon ? yes($0) : no($0) }
        case .call(let name, let arguments):
            return call(name, arguments)
        }
    }

    private func assignment(_ target: EELNode, _ op: String, _ value: @escaping Eval) -> Eval {
        func combine(_ old: Double, _ new: Double) -> Double {
            switch op {
            case "+=": return old + new
            case "-=": return old - new
            case "*=": return old * new
            case "/=": return new == 0 ? 0 : old / new
            case "%=": return Self.modulo(old, new)
            default: return new
            }
        }
        switch target {
        case .variable(let name):
            let slot = variables.slot(name)
            return { vars in
                let result = combine(vars.values[slot], value(vars))
                vars.values[slot] = result
                return result
            }
        case .call(let buffer, let arguments) where arguments.count == 1:
            let index = compile(arguments[0])
            let global = buffer == "gmegabuf"
            return { vars in
                let i = Int(index(vars) + Self.epsilon)
                guard i >= 0, i < 8_388_608 else { return 0 }
                let new = value(vars)
                if global {
                    if i >= vars.global.cells.count { vars.global.cells += Array(repeating: 0, count: i + 1 - vars.global.cells.count) }
                    vars.global.cells[i] = combine(vars.global.cells[i], new)
                    return vars.global.cells[i]
                }
                if i >= vars.megabuf.count { vars.megabuf += Array(repeating: 0, count: i + 1 - vars.megabuf.count) }
                vars.megabuf[i] = combine(vars.megabuf[i], new)
                return vars.megabuf[i]
            }
        default:
            return { _ in 0 }
        }
    }

    static func modulo(_ a: Double, _ b: Double) -> Double {
        let d = Int(abs(b))
        guard d != 0 else { return 0 }
        return Double(Int(abs(a)) % d)
    }

    private func binary(_ op: String, _ a: @escaping Eval, _ b: @escaping Eval) -> Eval {
        switch op {
        case "+": return { a($0) + b($0) }
        case "-": return { a($0) - b($0) }
        case "*": return { a($0) * b($0) }
        case "/":
            return { vars in
                let d = b(vars)
                return d == 0 ? 0 : a(vars) / d
            }
        case "%": return { Self.modulo(a($0), b($0)) }
        case "^": return { Self.power(a($0), b($0)) }
        case "==": return { abs(a($0) - b($0)) < Self.epsilon ? 1 : 0 }
        case "!=": return { abs(a($0) - b($0)) >= Self.epsilon ? 1 : 0 }
        case "<": return { a($0) < b($0) ? 1 : 0 }
        case ">": return { a($0) > b($0) ? 1 : 0 }
        case "<=": return { a($0) <= b($0) ? 1 : 0 }
        case ">=": return { a($0) >= b($0) ? 1 : 0 }
        case "&&": return { abs(a($0)) >= Self.epsilon && abs(b($0)) >= Self.epsilon ? 1 : 0 }
        case "||": return { abs(a($0)) >= Self.epsilon || abs(b($0)) >= Self.epsilon ? 1 : 0 }
        case "&": return { Double(Int(a($0)) & Int(b($0))) }
        case "|": return { Double(Int(a($0)) | Int(b($0))) }
        default: return { _ in 0 }
        }
    }

    static func power(_ a: Double, _ b: Double) -> Double {
        let result = pow(a, b)
        return result.isFinite ? result : 0
    }

    private func call(_ name: String, _ arguments: [EELNode]) -> Eval {
        let args = arguments.map(compile)
        func arg(_ i: Int) -> Eval { i < args.count ? args[i] : { _ in 0 } }
        let a = arg(0), b = arg(1), c = arg(2)
        func finite(_ f: @escaping (Double) -> Double) -> Eval {
            return { vars in
                let value = f(a(vars))
                return value.isFinite ? value : 0
            }
        }
        switch name {
        case "sin": return finite(sin)
        case "cos": return finite(cos)
        case "tan": return finite(tan)
        case "asin": return finite(asin)
        case "acos": return finite(acos)
        case "atan": return finite(atan)
        case "atan2": return { atan2(a($0), b($0)) }
        case "sqr": return { let x = a($0); return x * x }
        case "sqrt": return finite { sqrt(abs($0)) }
        case "invsqrt": return finite { 1 / sqrt(abs($0)) }
        case "pow": return { Self.power(a($0), b($0)) }
        case "exp": return finite(exp)
        case "log": return finite(log)
        case "log10": return finite(log10)
        case "abs": return { abs(a($0)) }
        case "min": return { min(a($0), b($0)) }
        case "max": return { max(a($0), b($0)) }
        case "sign": return { let x = a($0); return x > 0 ? 1 : x < 0 ? -1 : 0 }
        case "int", "floor": return { floor(a($0)) }
        case "ceil": return { ceil(a($0)) }
        case "fmod": return { vars in
            let d = b(vars)
            return d == 0 ? 0 : fmod(a(vars), d)
        }
        case "rand": return { vars in
            let x = a(vars)
            return x < 1 ? Double.random(in: 0..<1) * max(0, x) : floor(Double.random(in: 0..<1) * floor(x))
        }
        case "above": return { a($0) > b($0) ? 1 : 0 }
        case "below": return { a($0) < b($0) ? 1 : 0 }
        case "equal": return { abs(a($0) - b($0)) < Self.epsilon ? 1 : 0 }
        case "if": return { abs(a($0)) >= Self.epsilon ? b($0) : c($0) }
        case "band": return { abs(a($0)) >= Self.epsilon && abs(b($0)) >= Self.epsilon ? 1 : 0 }
        case "bor": return { abs(a($0)) >= Self.epsilon || abs(b($0)) >= Self.epsilon ? 1 : 0 }
        case "bnot": return { abs(a($0)) < Self.epsilon ? 1 : 0 }
        case "sigmoid": return { vars in
            let t = 1 + exp(-a(vars) * b(vars))
            return abs(t) > 0.00001 ? 1 / t : 0
        }
        case "exec2": return { _ = a($0); return b($0) }
        case "exec3": return { _ = a($0); _ = b($0); return c($0) }
        case "megabuf", "gmegabuf":
            let global = name == "gmegabuf"
            return { vars in
                let i = Int(a(vars) + Self.epsilon)
                let cells = global ? vars.global.cells : vars.megabuf
                return i >= 0 && i < cells.count ? cells[i] : 0
            }
        case "loop":
            return { vars in
                let count = min(Int(a(vars)), Self.maxIterations)
                var last = 0.0
                if count > 0 { for _ in 0..<count { last = b(vars) } }
                return last
            }
        case "while":
            return { vars in
                var iterations = 0
                while abs(a(vars)) >= Self.epsilon, iterations < Self.maxIterations { iterations += 1 }
                return 0
            }
        default:
            // Unknown functions do nothing, like a missing plug-in function.
            return { vars in
                for f in args { _ = f(vars) }
                return 0
            }
        }
    }
}
