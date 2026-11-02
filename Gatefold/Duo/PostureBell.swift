#if DEBUG
import Foundation

/// DEBUG only: a Darwin notification that turns the reader's posture mid-session, for filming the
/// unfold on a simulator whose hinge can't be moved. Ring it with
/// `xcrun simctl spawn <device> notifyutil -p com.ourostack.gatefold.posture`.
enum PostureBell {
    static let name = "com.ourostack.gatefold.posture"
    static let rang = Notification.Name("PostureBell.rang")
    nonisolated(unsafe) private static var listening = false

    static func listen() {
        guard !listening else { return }
        listening = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { NotificationCenter.default.post(name: PostureBell.rang, object: nil) }
            },
            name as CFString, nil, .deliverImmediately)
    }
}
#endif
