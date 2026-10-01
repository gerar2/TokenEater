import Foundation

protocol CredentialsFileReaderProtocol: Sendable {
    func readToken() -> String?
    func tokenExists() -> Bool
    /// The whole credentials file, for callers that need the refresh token.
    func readPayload() -> Data?
}
