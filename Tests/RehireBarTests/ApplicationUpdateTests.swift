import Foundation
import XCTest
@testable import RehireBar

final class ApplicationUpdateTests: XCTestCase {
    func testVersionDisplayUsesMarketingVersionAndBuildWithoutInventingMissingValues() {
        let packaged = ApplicationVersion(info: [
            "CFBundleName": "RehireBar", "CFBundleShortVersionString": "0.5.3", "CFBundleVersion": "15",
        ])
        XCTAssertEqual(packaged.displayText, "RehireBar 0.5.3 (15)")
        let development = ApplicationVersion(info: [:])
        XCTAssertNil(development.version)
        XCTAssertNil(development.build)
        XCTAssertEqual(development.displayText, "RehireBar version unavailable")
        XCTAssertNil(ApplicationVersion(info: ["CFBundleVersion": "  "]).build)
    }

    func testUpdateConfigurationRequiresHTTPSAndAnEd25519PublicKey() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let good: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key]
        XCTAssertNotNil(ApplicationUpdateConfiguration(info: good))
        for url in ["http://example.com/feed.xml", "file:///tmp/feed.xml", "https://user:password@example.com/feed.xml"] {
            XCTAssertNil(ApplicationUpdateConfiguration(info: ["SUFeedURL": url, "SUPublicEDKey": key]))
        }
        XCTAssertNil(ApplicationUpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed.xml"]))
        XCTAssertNil(ApplicationUpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed.xml", "SUPublicEDKey": "invalid"]))
    }

    func testClientInitializationUsesTheSuppliedVersionAndEscapesJSON() throws {
        let version = "0.5.3\"test"
        let data = CodexAppServerClient.makeInitializeRequest(version: version)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parameters = try XCTUnwrap(object["params"] as? [String: Any])
        let client = try XCTUnwrap(parameters["clientInfo"] as? [String: Any])
        XCTAssertEqual(client["version"] as? String, version)
        XCTAssertEqual(client["name"] as? String, "rehirebar")
        XCTAssertEqual(data.last, 0x0A)
        let missing = String(decoding: CodexAppServerClient.makeInitializeRequest(version: nil), as: UTF8.self)
        XCTAssertTrue(missing.contains("development"))
        XCTAssertFalse(missing.contains("0.5.0"))
    }
}
