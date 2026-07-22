import Foundation
import Security

public struct AgentEndpointConfig: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    public let apiKey: String
    public let model: String

    public init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public var description: String {
        "AgentEndpointConfig(baseURL: \(baseURL.absoluteString), apiKey: <redacted>, model: \(model))"
    }

    public var debugDescription: String { description }
}

public protocol AgentCredentialStore: Sendable {
    func endpointConfig() throws -> AgentEndpointConfig
}

public enum AgentCredentialStoreError: LocalizedError, Equatable, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "agent endpoint configuration is missing"
        case .invalidConfiguration:
            return "agent endpoint configuration is invalid"
        case .keychain(let status):
            return "agent credential keychain operation failed (status \(status))"
        }
    }
}

private struct StoredAgentEndpointConfig: Codable {
    let baseURL: URL
    let apiKey: String
    let model: String

    init(_ config: AgentEndpointConfig) {
        baseURL = config.baseURL
        apiKey = config.apiKey
        model = config.model
    }

    var endpointConfig: AgentEndpointConfig {
        AgentEndpointConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}

/// Injection-friendly credential store for tests and non-persistent previews.
public struct InMemoryAgentCredentialStore: AgentCredentialStore {
    private let config: AgentEndpointConfig?

    public init(config: AgentEndpointConfig? = nil) {
        self.config = config
    }

    public func endpointConfig() throws -> AgentEndpointConfig {
        guard let config else { throw AgentCredentialStoreError.missingConfiguration }
        return config
    }
}

/// Stores the complete endpoint configuration as a generic-password Keychain item.
/// No API key is retained in the value-type store itself.
public struct KeychainAgentCredentialStore: AgentCredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "app.txtnimal.agent", account: String = "endpoint-config") {
        self.service = service
        self.account = account
    }

    public func endpointConfig() throws -> AgentEndpointConfig {
        var result: CFTypeRef?
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw AgentCredentialStoreError.missingConfiguration }
        guard status == errSecSuccess else { throw AgentCredentialStoreError.keychain(status) }
        guard let data = result as? Data,
              let config = try? JSONDecoder().decode(StoredAgentEndpointConfig.self, from: data) else {
            throw AgentCredentialStoreError.invalidConfiguration
        }
        return config.endpointConfig
    }

    public func save(_ config: AgentEndpointConfig) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(StoredAgentEndpointConfig(config))
        } catch {
            throw AgentCredentialStoreError.invalidConfiguration
        }

        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AgentCredentialStoreError.keychain(updateStatus)
        }

        var newItem = itemQuery
        newItem[kSecValueData as String] = data
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AgentCredentialStoreError.keychain(addStatus) }
    }

    public func remove() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentCredentialStoreError.keychain(status)
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
