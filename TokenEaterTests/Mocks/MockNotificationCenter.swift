import Foundation
import UserNotifications

final class MockNotificationCenter: NotificationCenterProtocol {
    /// Every request handed to `add`, in order. Kept whole so tests can assert
    /// on titles (profile prefix) as well as identifiers.
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedIDs: [String] = []
    var stubbedStatus: UNAuthorizationStatus = .notDetermined
    var requestAuthorizationCalled = false

    var addedIDs: [String] { addedRequests.map(\.identifier) }

    /// Title of the most recent request with that identifier, if any.
    func title(for identifier: String) -> String? {
        addedRequests.last { $0.identifier == identifier }?.content.title
    }

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {}
    func requestAuthorization() { requestAuthorizationCalled = true }
    func authorizationStatus() async -> UNAuthorizationStatus { stubbedStatus }
    func add(_ request: UNNotificationRequest) { addedRequests.append(request) }
    func removePending(identifiers: [String]) { removedIDs.append(contentsOf: identifiers) }
}
