import Foundation

final class MockCredentialsFileReader: CredentialsFileReaderProtocol, @unchecked Sendable {
    var storedToken: String?
    var fileExists: Bool = false
    var payload: Data?

    func readToken() -> String? { storedToken }
    func tokenExists() -> Bool { fileExists }
    func readPayload() -> Data? {
        if let payload { return payload }
        guard let storedToken else { return nil }
        return "{\"claudeAiOauth\":{\"accessToken\":\"\(storedToken)\"}}".data(using: .utf8)
    }
}
