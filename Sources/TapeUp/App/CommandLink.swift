import Foundation

/// How a `TapeUp` command reaches the running app: a distributed
/// notification carries the request, and the app answers on another with
/// the same id, first that it took the request, then with the outcome.
/// Both sides run as the same user on the same Mac.
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
                // Moving recordings can take minutes; the command waits once it knows.
                send(["id": id, "taken": "1"])
                model.handle(request) { refusal, folder, output in
                    var answer = ["id": id]
                    if let refusal {
                        answer["error"] = refusal.code
                        answer["message"] = refusal.message
                        answer["suggestion"] = refusal.suggestion
                        answer["retryable"] = refusal.retryable ? "1" : "0"
                    }
                    answer["output"] = output
                    answer["folder"] = folder?.path
                    send(answer)
                }
            }
        }
    }

    private static func send(_ answer: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            reply, object: nil, userInfo: answer, deliverImmediately: true)
    }
}

/// Why the app did not do what a command asked, in the command line's terms.
struct Refusal: Error, Sendable {
    var code: String
    var message: String
    var suggestion: String?
    var retryable = false

    init(_ code: String, _ message: String, suggestion: String? = nil, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.suggestion = suggestion
        self.retryable = retryable
    }
}
