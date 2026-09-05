import AgentStatusCore
import Darwin
import Foundation
import XCTest
@testable import RehireBar

final class ModelDisplayConfigurationTests: XCTestCase {
    private var defaults: ModelDisplayConfiguration {
        ModelDisplayConfigurationLoader.bundledConfiguration
    }

    func testDefaultDocumentAndRequestedAstraSpellings() throws {
        try defaults.validate()
        XCTAssertEqual(defaults.modelAliases["gpt6-astra"], "6.0A")
        let formatter = ModelDisplayFormatter(configuration: defaults)
        for name in ["GPT6-astra", "gpt-6-astra", "gpt-6.0-astra", "  GPT6-ASTRA  "] {
            XCTAssertEqual(formatter.modelName(name), "6.0A")
        }
        XCTAssertEqual(formatter.modelAndEffort(model: "gpt-6-astra", effort: "xhigh"), "6.0A·XH")
    }

    func testProviderExactAliasPrecedesGlobalAliasAndFamilyRule() {
        var configuration = defaults
        configuration.modelAliases["gpt-6-astra"] = "Global"
        configuration.providerModelAliases = ["agent-a": ["GPT-6-ASTRA": "Local"]]
        let formatter = ModelDisplayFormatter(configuration: configuration)
        XCTAssertEqual(formatter.modelName("gpt-6-astra", providerID: "agent-a"), "Local")
        XCTAssertEqual(formatter.modelName("gpt-6-astra", providerID: "agent-b"), "Global")
        XCTAssertEqual(formatter.modelName("gpt-6-astra", providerID: "AGENT-A"), "Global")
    }

    func testRulesAndEffortTableCanBeChangedWithoutUIChanges() {
        var configuration = defaults
        configuration.modelAliases = [:]
        configuration.rules.stripPrefixes = ["acme/"]
        configuration.rules.integerVersionSuffix = ""
        configuration.rules.uppercaseUnknownEffort = false
        configuration.rules.effortSeparator = "/"
        configuration.modelSuffixAliases = ["orbit": "O"]
        configuration.effortAliases = ["deep": "D"]
        let formatter = ModelDisplayFormatter(configuration: configuration)
        XCTAssertEqual(formatter.modelName("acme/7-orbit"), "7O")
        XCTAssertEqual(formatter.modelAndEffort(model: "acme/7-orbit", effort: "deep"), "7O/D")
        XCTAssertEqual(formatter.effortName("future-level"), "future-level")
        XCTAssertEqual(formatter.modelName("gpt-6-astra"), "gpt-6-astra")
    }

    func testUnknownFamiliesAndVariantSuffixesAreNotGuessed() {
        let formatter = ModelDisplayFormatter(configuration: defaults)
        XCTAssertEqual(formatter.modelName("gpt-6.1-nova"), "6.1-nova")
        XCTAssertEqual(formatter.modelName("gpt-6-astra-pro"), "6-astra-pro")
        XCTAssertEqual(formatter.modelName("gpt-6-astra-2026-09-01"), "6-astra-2026-09-01")
        XCTAssertEqual(formatter.modelName("vendor/some-new-model"), "vendor/some-new-model")
        XCTAssertEqual(formatter.modelName("o4-mini"), "o4m")
        XCTAssertEqual(formatter.modelName("gpt-7-astra"), "7.0A")
        XCTAssertNil(formatter.modelAndEffort(model: nil, effort: "high"))
        XCTAssertNil(formatter.modelAndEffort(model: "  ", effort: "high"))
        XCTAssertEqual(formatter.modelAndEffort(model: "gpt-6-astra", effort: "  "), "6.0A")
    }

    func testCaseSensitivePolicyAndAmbiguousCaseInsensitiveAliases() throws {
        var configuration = defaults
        configuration.modelAliases = ["Model": "A", "model": "B"]
        XCTAssertThrowsError(try configuration.validate()) {
            XCTAssertEqual($0 as? ModelDisplayConfiguration.ValidationError, .ambiguousMapping)
        }
        configuration.rules.caseSensitive = true
        try configuration.validate()
        let formatter = ModelDisplayFormatter(configuration: configuration)
        XCTAssertEqual(formatter.modelName("Model"), "A")
        XCTAssertEqual(formatter.modelName("model"), "B")
        XCTAssertEqual(formatter.modelName("MODEL"), "MODEL")
    }

    func testInvalidPoliciesAreRejectedAndFormatterFallsBackToOriginal() {
        var unsupported = defaults
        unsupported.schemaVersion = 2
        XCTAssertThrowsError(try unsupported.validate())
        XCTAssertEqual(ModelDisplayFormatter(configuration: unsupported).modelName("gpt-6-astra"), "gpt-6-astra")
        var emptyPrefix = defaults
        emptyPrefix.rules.stripPrefixes = [""]
        XCTAssertThrowsError(try emptyPrefix.validate())
        var invalidAlias = defaults
        invalidAlias.modelAliases["gpt-6-astra"] = "bad\nlabel"
        XCTAssertThrowsError(try invalidAlias.validate())
        invalidAlias.modelAliases["gpt-6-astra"] = ""
        XCTAssertThrowsError(try invalidAlias.validate())
        XCTAssertThrowsError(try ModelDisplayConfiguration.decode(Data(#"{"schemaVersion":1}"#.utf8)))
    }

    func testOverrideReloadsAndRemovalOrInvalidContentRestoresDefaults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "model-display.json")
        let loader = ModelDisplayConfigurationLoader(overrideURL: url, fallback: defaults)
        var custom = defaults
        custom.modelAliases["gpt-6-astra"] = "Custom"
        try JSONEncoder().encode(custom).write(to: url, options: .atomic)
        XCTAssertEqual(loader.load(), custom)
        custom.modelAliases["gpt-6-astra"] = "Updated"
        try JSONEncoder().encode(custom).write(to: url, options: .atomic)
        XCTAssertEqual(loader.load(), custom)
        try Data("invalid".utf8).write(to: url, options: .atomic)
        XCTAssertEqual(loader.load(), defaults)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(loader.load(), defaults)
    }

    func testOverrideRejectsOversizedFileSymlinkAndNamedPipe() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "model-display.json")
        let loader = ModelDisplayConfigurationLoader(overrideURL: url, fallback: defaults)
        var custom = defaults
        custom.modelAliases["gpt-6-astra"] = "Unsafe"
        let encoded = try JSONEncoder().encode(custom)
        var large = encoded
        large.append(Data(repeating: 0x20, count: ModelDisplayConfigurationLoader.maximumBytes))
        try large.write(to: url)
        XCTAssertEqual(loader.load(), defaults)
        try FileManager.default.removeItem(at: url)
        let target = directory.appending(path: "target.json")
        try encoded.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertEqual(loader.load(), defaults)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertEqual(loader.load(), defaults)
    }

    @MainActor
    func testViewModelUsesPolicyButKeepsOriginalModelAndEffortFacts() {
        var configuration = defaults
        configuration.providerModelAliases = ["example-agent": ["GPT6-astra": "Override"]]
        let session = CurrentSessionSnapshot(
            sessionID: "session", threadID: "task", usedTokens: 0, contextWindow: 0,
            model: "GPT6-astra", effort: "xhigh", observedAt: .now,
            providerID: "example-agent", hostID: "scope"
        )
        let model = TouchBarStatusViewModel(
            status: .init(usage: nil, session: session), modelDisplay: configuration
        )
        XCTAssertEqual(model.sessions.first?.modelID, "GPT6-astra")
        XCTAssertEqual(model.sessions.first?.effort, "xhigh")
        XCTAssertEqual(model.sessions.first?.modelEffortText, "Override·XH")
        XCTAssertEqual(model.sessions.first?.id, "example-agent|scope|task")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
