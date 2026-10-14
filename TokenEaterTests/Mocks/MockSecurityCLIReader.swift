import Foundation

final class MockSecurityCLIReader: SecurityCLIReaderProtocol, @unchecked Sendable {
    var token: String?
    /// Raw payload returned by `readPayload()`. When nil, a payload is
    /// synthesised from `token` so token-only tests keep working.
    var payload: String?
    var readCallCount = 0

    func readToken() -> String? {
        readCallCount += 1
        return token
    }

    func readPayload() -> String? {
        readCallCount += 1
        if let payload { return payload }
        guard let token else { return nil }
        return "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
    }
}
