import Foundation

/// How a `TapeUp` command reaches the running app: a distributed
/// notification carries the request, and the app answers on another with
/// the same id. Both sides run as the same user on the same Mac.
enum CommandLink {
    static let request = Notification.Name("app.tapeup.request")
    static let reply = Notification.Name("app.tapeup.reply")

    /// Starts answering requests; held for the app's lifetime.
    @MainActor static func listen(_ model: AppModel) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) {
            note in
            guard let request = note.userInfo as? [String: String], let id = request["id"] else { return }
            MainActor.assumeIsolated {
                // Another copy of TapeUp, on another recordings folder, answers its own.
                guard request["root"] == model.root.standardizedFileURL.path else { return }
                model.handle(request) { problem, folder in
                    var answer = ["id": id]
                    answer["error"] = problem
                    answer["folder"] = folder?.path
                    DistributedNotificationCenter.default().postNotificationName(
                        reply, object: nil, userInfo: answer, deliverImmediately: true)
                }
            }
        }
    }
}
