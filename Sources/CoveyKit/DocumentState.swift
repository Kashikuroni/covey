import Foundation

public struct DocumentContext: Codable, Equatable, Sendable {
    public var sourceSession: String
    public var root: String
    public var projectKey: String
    public init(sourceSession: String, root: String, projectKey: String) {
        self.sourceSession = sourceSession; self.root = root; self.projectKey = projectKey
    }
}

public struct DocumentPosition: Codable, Equatable, Sendable {
    public var anchorID: String?
    public var offset: Double
    public var progress: Double
    public init(anchorID: String? = nil, offset: Double = 0, progress: Double = 0) {
        self.anchorID = anchorID; self.offset = offset; self.progress = progress
    }
}

public struct DocumentLocation: Codable, Equatable, Sendable {
    public var path: String
    public var fragment: String?
    public var position: DocumentPosition?
    public init(path: String, fragment: String? = nil, position: DocumentPosition? = nil) {
        self.path = path; self.fragment = fragment; self.position = position
    }
}

public struct PersistedDocumentZone: Codable, Equatable, Sendable {
    public var context: DocumentContext
    public var location: DocumentLocation?
    public var width: Double?
    public var sourceMode: Bool
    public init(context: DocumentContext, location: DocumentLocation? = nil,
                width: Double? = nil, sourceMode: Bool = false) {
        self.context = context; self.location = location; self.width = width; self.sourceMode = sourceMode
    }
}

public enum DocumentPresetID: String, Codable, CaseIterable, Sendable {
    case common, rust, node, react, vue, python, next, nuxt, swift
}

/// Nil overrides inherit the global/default policy. Explicit false disables it.
public struct DocumentScopeExclusions: Codable, Equatable, Sendable {
    public var useBuiltins: Bool?
    public var presetOverrides: [DocumentPresetID: Bool]
    public var ruleOverrides: [String: Bool]
    public var customRules: String
    public init(useBuiltins: Bool? = nil, presetOverrides: [DocumentPresetID: Bool] = [:],
                ruleOverrides: [String: Bool] = [:], customRules: String = "") {
        self.useBuiltins = useBuiltins; self.presetOverrides = presetOverrides
        self.ruleOverrides = ruleOverrides; self.customRules = customRules
    }
}

public struct DocumentExclusionConfiguration: Codable, Equatable, Sendable {
    public var global: DocumentScopeExclusions
    public var projects: [String: DocumentScopeExclusions]
    public init(global: DocumentScopeExclusions = .init(), projects: [String: DocumentScopeExclusions] = [:]) {
        self.global = global; self.projects = projects
    }
}

public struct PersistedDocumentRecents: Codable, Equatable, Sendable {
    public var root: String
    public var paths: [String]
    public init(root: String, paths: [String]) { self.root = root; self.paths = paths }
    public mutating func opened(_ path: String) {
        paths.removeAll { $0 == path }; paths.insert(path, at: 0)
        paths = Array(paths.prefix(30))
    }
}
