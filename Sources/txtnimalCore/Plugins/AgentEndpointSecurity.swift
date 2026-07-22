import Foundation

enum AgentEndpointSecurity {
    static func assertSecure(_ url: URL) throws {
        switch url.scheme?.lowercased() {
        case "https":
            return
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? ""):
            return  // ponytail: loopback http allowed for local models (Ollama/LM Studio)
        default:
            throw HTTPAgentTransportError.insecureEndpoint
        }
    }
}
