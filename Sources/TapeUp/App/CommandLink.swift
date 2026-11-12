import Foundation

/// How a `TapeUp` command reaches the running app: a distributed
/// notification carries the request, and the app answers on another with
/// the same id, first that it took the request, then with the outcome.
/// Both sides run as the same user on the same Mac.
enum CommandLink {
    static let version = "2"
    private static let prefix = "cli2:"

    static func wireRequest(_ request: [String: String]) -> [String: String] {
        var request = request
        request["command"] = prefix + (request["command"] ?? "")
        return request
    }

    static func accepts(_ reply: [String: String]) -> Bool { reply["protocol"] == version }

    static func appRequest(_ request: [String: String]) -> [String: String]? {
        guard let command = request["command"], command.hasPrefix(prefix) else { return nil }
        var request = request
        request["command"] = String(command.dropFirst(prefix.count))
        return request
    }

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
                guard let request = appRequest(request) else {
                    send([
                        "id": id, "protocol": version, "error": "app_outdated",
                        "message": "This CLI uses an older command protocol.",
                        "suggestion": "Use help from the running app's executable and run its command again.",
                        "retryable": "0",
                    ])
                    return
                }
                send(["id": id, "protocol": version, "taken": "1"])
                model.handle(
                    request,
                    progress: { progress in
                        send(["id": id, "protocol": version, "progress": progress])
                    }
                ) { refusal, folder, output in
                    var answer = ["id": id, "protocol": version]
                    if let refusal {
                        answer["stamp"] = refusal.stamp
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
    var stamp: String?

    init(_ code: String, _ message: String, suggestion: String? = nil, retryable: Bool = false, stamp: String? = nil) {
        self.stamp = stamp
        self.code = code
        self.message = message
        self.suggestion = suggestion
        self.retryable = retryable
    }
}
