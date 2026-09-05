import Foundation

/// Versioned, editable display policy. Raw model IDs and task identities are never changed.
public struct ModelDisplayConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var rules: ModelDisplayRules
    public var modelAliases: [String: String]
    public var modelSuffixAliases: [String: String]
    public var providerModelAliases: [String: [String: String]]
    public var effortAliases: [String: String]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        rules: ModelDisplayRules = .init(),
        modelAliases: [String: String] = [:],
        modelSuffixAliases: [String: String] = [:],
        providerModelAliases: [String: [String: String]] = [:],
        effortAliases: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.modelAliases = modelAliases
        self.modelSuffixAliases = modelSuffixAliases
        self.providerModelAliases = providerModelAliases
        self.effortAliases = effortAliases
    }

    /// Safe fallback when no valid policy is available: display the original values.
    public static let passthrough = ModelDisplayConfiguration()

    public enum ValidationError: Error, Equatable {
        case unsupportedVersion
        case invalidRule
        case invalidMapping
        case ambiguousMapping
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedVersion
        }
        guard rules.stripPrefixes.count <= 32,
              rules.stripPrefixes.allSatisfy({ Self.validText($0, maximumLength: 64) }),
              Self.validText(rules.integerVersionSuffix, maximumLength: 8, allowsEmpty: true),
              Self.validText(rules.effortSeparator, maximumLength: 8, allowsEmpty: true)
        else { throw ValidationError.invalidRule }
        try validateAliases(modelAliases)
        try validateAliases(modelSuffixAliases)
        guard modelSuffixAliases.keys.allSatisfy({ !$0.contains("-") }),
              providerModelAliases.count <= 256 else { throw ValidationError.invalidMapping }
        for (providerID, aliases) in providerModelAliases {
            guard Self.validText(providerID, maximumLength: 512) else {
                throw ValidationError.invalidMapping
            }
            try validateAliases(aliases)
        }
        try validateAliases(effortAliases)
    }

    public static func decode(_ data: Data) throws -> Self {
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate()
        return configuration
    }

    private func validateAliases(_ aliases: [String: String]) throws {
        guard aliases.count <= 1024 else { throw ValidationError.invalidMapping }
        var keys = Set<String>()
        for (key, value) in aliases {
            guard Self.validText(key, maximumLength: 512),
                  Self.validText(value, maximumLength: 64) else {
                throw ValidationError.invalidMapping
            }
            let normalized = rules.caseSensitive ? key : key.lowercased()
            guard keys.insert(normalized).inserted else {
                throw ValidationError.ambiguousMapping
            }
        }
    }

    private static func validText(
        _ value: String, maximumLength: Int, allowsEmpty: Bool = false
    ) -> Bool {
        (allowsEmpty || !value.isEmpty)
            && value.count <= maximumLength
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct ModelDisplayRules: Codable, Equatable, Sendable {
    public var caseSensitive: Bool
    public var stripPrefixes: [String]
    public var integerVersionSuffix: String
    public var uppercaseUnknownEffort: Bool
    public var effortSeparator: String

    public init(
        caseSensitive: Bool = false,
        stripPrefixes: [String] = [],
        integerVersionSuffix: String = "",
        uppercaseUnknownEffort: Bool = false,
        effortSeparator: String = "·"
    ) {
        self.caseSensitive = caseSensitive
        self.stripPrefixes = stripPrefixes
        self.integerVersionSuffix = integerVersionSuffix
        self.uppercaseUnknownEffort = uppercaseUnknownEffort
        self.effortSeparator = effortSeparator
    }
}

/// Foundation-only formatter shared by the app and integrations. It interprets
/// explicit policy data; it never guesses a family from an unfamiliar model ID.
public struct ModelDisplayFormatter: Sendable {
    private let configuration: ModelDisplayConfiguration

    public init(configuration: ModelDisplayConfiguration) {
        self.configuration = (try? configuration.validate()) != nil ? configuration : .passthrough
    }

    public func modelName(_ rawModel: String, providerID: String? = nil) -> String {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let providerID,
           let aliases = configuration.providerModelAliases[providerID],
           let alias = lookup(model, in: aliases) { return alias }
        if let alias = lookup(model, in: configuration.modelAliases) { return alias }

        var base = model
        if let prefix = configuration.rules.stripPrefixes.first(where: {
            normalized(model).hasPrefix(normalized($0))
        }) {
            base = String(model.dropFirst(prefix.count))
        }
        let components = base.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count > 1,
              let suffix = components.last,
              let alias = lookup(String(suffix), in: configuration.modelSuffixAliases)
        else { return base.isEmpty ? model : base }
        var version = components.dropLast().joined(separator: "-")
        guard !version.isEmpty else { return base }
        if version.utf8.allSatisfy({ (48...57).contains($0) }) {
            version += configuration.rules.integerVersionSuffix
        }
        return version + alias
    }

    public func effortName(_ rawEffort: String) -> String {
        let effort = rawEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return lookup(effort, in: configuration.effortAliases)
            ?? (configuration.rules.uppercaseUnknownEffort ? effort.uppercased() : effort)
    }

    public func modelAndEffort(
        model: String?, effort: String?, providerID: String? = nil
    ) -> String? {
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let label = modelName(model, providerID: providerID)
        guard let effort, !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return label
        }
        return label + configuration.rules.effortSeparator + effortName(effort)
    }

    private func lookup(_ value: String, in aliases: [String: String]) -> String? {
        let key = normalized(value)
        return aliases.first { normalized($0.key) == key }?.value
    }

    private func normalized(_ value: String) -> String {
        configuration.rules.caseSensitive ? value : value.lowercased()
    }
}
