import Foundation
import CoveyKit

enum DocumentRuleSource: Equatable, Sendable { case builtin(String), global(line: Int), project(line: Int) }
struct DocumentRuleDiagnostic: Equatable, Sendable { let line: Int; let message: String }
struct DocumentRuleCompileError: Error { let diagnostics: [DocumentRuleDiagnostic] }
struct DocumentExclusionDecision: Equatable {
    var excluded = false
    var source: DocumentRuleSource?
    var pattern: String?
    var excludedAncestor: String?
}

struct DocumentExclusionRules: @unchecked Sendable {
    private struct Rule {
        let pattern: String
        let regex: NSRegularExpression
        let directoryOnly: Bool
        let negated: Bool
        let source: DocumentRuleSource
    }
    private var rules: [Rule]
    static func compile(configuration: DocumentExclusionConfiguration, projectKey: String,
                        detected: Set<DocumentPresetID>) throws -> Self {
        let global = configuration.global, project = configuration.projects[projectKey] ?? .init()
        var input: [(String, DocumentRuleSource)] = []
        if project.useBuiltins ?? global.useBuiltins ?? true {
            var enabled = detected.union([.common])
            for preset in DocumentPresetID.allCases {
                if let value = project.presetOverrides[preset] ?? global.presetOverrides[preset] {
                    if value { enabled.insert(preset) } else { enabled.remove(preset) }
                }
            }
            if !enabled.isDisjoint(with: [.react, .vue, .next, .nuxt]),
               (project.presetOverrides[.node] ?? global.presetOverrides[.node]) != false { enabled.insert(.node) }
            for preset in DocumentPresetID.allCases where enabled.contains(preset) {
                for pattern in DocumentPresets.rules[preset] ?? [] where (project.ruleOverrides[pattern] ?? global.ruleOverrides[pattern]) != false {
                    input.append((pattern, .builtin(preset.rawValue)))
                }
            }
            for pattern in DocumentPresets.optionalRules where (project.ruleOverrides[pattern] ?? global.ruleOverrides[pattern]) == true {
                input.append((pattern, .builtin("optional")))
            }
        }
        input += global.customRules.components(separatedBy: "\n").enumerated().map { ($0.element, .global(line: $0.offset + 1)) }
        input += project.customRules.components(separatedBy: "\n").enumerated().map { ($0.element, .project(line: $0.offset + 1)) }
        var parsed: [Rule] = [], diagnostics: [DocumentRuleDiagnostic] = []
        for (line, source) in input {
            do { if let rule = try parse(line, source: source) { parsed.append(rule) } }
            catch {
                let number: Int
                switch source { case .global(let n), .project(let n): number = n; case .builtin: number = 0 }
                diagnostics.append(.init(line: number, message: "Invalid pattern: \(line)"))
            }
        }
        if !diagnostics.isEmpty { throw DocumentRuleCompileError(diagnostics: diagnostics) }
        return Self(rules: parsed)
    }
    func decision(path: String, isDirectory: Bool) -> DocumentExclusionDecision {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return .init() }
        for i in 1...parts.count {
            let prefix = parts.prefix(i).joined(separator: "/"), directory = i < parts.count || isDirectory
            var result = DocumentExclusionDecision()
            for rule in rules where !rule.directoryOnly || directory {
                if rule.regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
                    result = .init(excluded: !rule.negated, source: rule.source, pattern: rule.pattern)
                }
            }
            if result.excluded {
                if i < parts.count { result.excludedAncestor = prefix }
                return result
            }
            if i == parts.count { return result }
        }
        return .init()
    }
    private static func parse(_ raw: String, source: DocumentRuleSource) throws -> Rule? {
        var chars = Array(raw.hasSuffix("\r") ? String(raw.dropLast()) : raw)
        while chars.last == " " {
            var escapes = 0, i = chars.count - 2
            while i >= 0 && chars[i] == "\\" { escapes += 1; i -= 1 }
            if escapes % 2 == 1 { break }
            chars.removeLast()
        }
        guard !chars.isEmpty, chars.first != "#" else { return nil }
        let pattern = String(chars), negated = chars.first == "!"
        if negated { chars.removeFirst() }
        let directoryOnly = chars.last == "/"
        if directoryOnly { chars.removeLast() }
        let anchored = chars.first == "/"
        if anchored { chars.removeFirst() }
        guard !chars.isEmpty else { return nil }
        var expression = anchored || chars.contains("/") ? "^" : "^(?:.*/)?", i = 0
        while i < chars.count {
            switch chars[i] {
            case "\\":
                i += 1; guard i < chars.count else { throw PatternError.invalid }
                expression += NSRegularExpression.escapedPattern(for: String(chars[i]))
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*", i == 0 || chars[i - 1] == "/",
                   i + 2 == chars.count || chars[i + 2] == "/" {
                    if i + 2 < chars.count { expression += "(?:.*/)?"; i += 2 }
                    else { expression += ".*"; i += 1 }
                } else { expression += "[^/]*" }
            case "?": expression += "[^/]"
            case "[":
                var j = i + 1; guard j < chars.count else { throw PatternError.invalid }
                var group = "["
                if chars[j] == "!" || chars[j] == "^" { group += "^"; j += 1 }
                let start = j
                while j < chars.count && chars[j] != "]" {
                    if chars[j] == "\\" {
                        j += 1; guard j < chars.count else { throw PatternError.invalid }
                        group += "\\" + String(chars[j])
                    } else { group += String(chars[j]) }
                    j += 1
                }
                guard j < chars.count, j > start else { throw PatternError.invalid }
                expression += group + "]"; i = j
            default: expression += NSRegularExpression.escapedPattern(for: String(chars[i]))
            }
            i += 1
        }
        return Rule(pattern: pattern, regex: try NSRegularExpression(pattern: expression + "$"), directoryOnly: directoryOnly, negated: negated, source: source)
    }
    private enum PatternError: Error { case invalid }
}
