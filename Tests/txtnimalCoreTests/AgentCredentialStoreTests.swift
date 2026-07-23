import Foundation
import XCTest
@testable import txtnimalCore

final class AgentCredentialStoreTests: XCTestCase {
    func testInMemoryStoreReturnsConfiguredEndpoint() throws {
        let config = AgentEndpointConfig(baseURL: try XCTUnwrap(URL(string: "https://llm.example/v1")),
                                         apiKey: "test-secret", model: "test-model")
        let store: any AgentCredentialStore = InMemoryAgentCredentialStore(config: config)

        XCTAssertEqual(try store.endpointConfig(), config)
    }

    func testInMemoryStoreWithoutConfigurationThrowsRecognizableError() {
        let store: any AgentCredentialStore = InMemoryAgentCredentialStore()

        XCTAssertThrowsError(try store.endpointConfig()) { error in
            XCTAssertEqual(error as? AgentCredentialStoreError, .missingConfiguration)
        }
    }

    func testEndpointConfigDescriptionsRedactAPIKey() {
        let config = AgentEndpointConfig(baseURL: URL(string: "https://llm.example/v1")!,
                                         apiKey: "description-secret", model: "test-model")

        for description in [String(describing: config), String(reflecting: config)] {
            XCTAssertFalse(description.contains("description-secret"))
            XCTAssertTrue(description.contains("<redacted>"))
        }
    }
}
