import AppKit
import Foundation
import Observation
import TapeUpCore

/// A coding agent the user already has, which TapeUp may ask for
/// suggestions: its own unmodified command, signed in by the user through
/// the tool's own sign-in. TapeUp never reads their credentials.
enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The official ways to install and sign in, run in Terminal.
    var installCommand: String {
        switch self {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex:
            FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew")
                ? "brew install --cask codex" : "npm install -g @openai/codex"
        }
    }

    var signInArguments: [String] {
        switch self {
        case .claude: ["auth", "login"]
        case .codex: ["login"]
        }
    }
}

enum AgentState: Equatable, Sendable {
    case checking, notInstalled, signedOut, signedIn
}

/// The agent the user picked in the ··· menu, its sign-in state, and the
/// calls: one at a time, the model given no tools and held to a JSON shape.
@MainActor @Observable
final class Agents {
    /// Nil until the user picks one; picking it is the consent. Read from
    /// the settings each time: `TapeUp agent off` changes them from outside.
    var chosen: AgentKind? {
        _ = version
        return testing ?? Self.chosen
    }
    private var version = 0
    /// For the UI test: an agent and model used without touching the
    /// settings the installed app reads.
    var testing: AgentKind?
    var testingModel: String?

    nonisolated static var chosen: AgentKind? {
        UserDefaults.standard.string(forKey: "agent").flatMap(AgentKind.init)
    }

    /// The model and effort `TapeUp agent` set for an agent; nil keeps
    /// TapeUp's choice (Sonnet at low effort, or Codex's own model at low).
    nonisolated static func setting(_ name: String, for kind: AgentKind) -> String? {
        UserDefaults.standard.string(forKey: "agent\(name)-\(kind.rawValue)")
    }

    private(set) var states: [AgentKind: AgentState] = [:]
    private var checkedAt = Date.distantPast
    private var checking: Task<Void, Never>?
    private var calls: Task<Void, Never>?

    /// The chosen agent can no longer be called: a dot on ··· says so.
    var needsAttention: Bool {
        guard let chosen, let state = states[chosen] else { return false }
        return state == .signedOut || state == .notInstalled
    }

    func state(of kind: AgentKind) -> AgentState { states[kind] ?? .checking }

    /// Picking Off or another agent also stops a call on the one withdrawn.
    func choose(_ kind: AgentKind?) {
        UserDefaults.standard.set(kind?.rawValue, forKey: "agent")
        version += 1
        Run.stopAll()
    }

    /// Checks both agents, at most every few seconds and one check at a
    /// time: when the Agent menu is about to open.
    func refresh() {
        guard checking == nil, Date().timeIntervalSince(checkedAt) > 3 else { return }
        checkedAt = Date()
        checking = Task {
            for kind in AgentKind.allCases {
                states[kind] = await AgentRunner.state(kind)
            }
            checking = nil
        }
    }

    /// The same, at launch and when the panel shows, only while an agent is
    /// on: with none picked, the user's tools are left alone.
    func refreshIfOn() {
        if chosen != nil { refresh() }
    }

    /// Checks again at once, whenever the last check was.
    func refreshNow() {
        checkedAt = .distantPast
        refresh()
    }

    /// The Agent menu, the same in ··· and on right-click: Off, then each
    /// agent as it stands. Only a signed-in agent can be picked.
    struct Row {
        var title: String
        var checked = false
        var enabled = true
        var action: @MainActor () -> Void
    }

    static let caption = "Suggests titles and names"

    var menuTitle: String { needsAttention ? "Agent · Signed Out" : "Agent" }

    var rows: [Row] {
        var rows = [Row(title: "Off", checked: chosen == nil) { [weak self] in self?.choose(nil) }]
        for kind in AgentKind.allCases {
            let picked = chosen == kind
            switch state(of: kind) {
            case .checking:
                rows.append(Row(title: kind.name, checked: picked, enabled: false) {})
            case .signedIn:
                rows.append(Row(title: kind.name, checked: picked) { [weak self] in self?.choose(kind) })
            case .signedOut:
                rows.append(
                    Row(title: "Sign In to \(kind.name)…", checked: picked) { [weak self] in self?.signIn(kind) })
            case .notInstalled:
                rows.append(Row(title: "Install \(kind.name)…", checked: picked) { [weak self] in self?.install(kind) })
            }
        }
        return rows
    }

    func install(_ kind: AgentKind) {
        Terminal.run(kind.installCommand)
        checkedAt = .distantPast
    }

    func signIn(_ kind: AgentKind) {
        guard let path = AgentRunner.found(kind)?.path else { return install(kind) }
        Terminal.run(([path] + kind.signInArguments).map(Terminal.quote).joined(separator: " "))
        // The state is checked again when the menu next opens.
        checkedAt = .distantPast
    }

    /// Asks the chosen agent, if any, waiting for earlier calls. A call
    /// tuned for speed that fails is tried once more with the user's own
    /// settings; a second failure is logged in the recording's
    /// `events.jsonl` and gives nil, and the next recording tries again.
    /// A call whose agent was withdrawn meanwhile gives nil quietly.
    func ask(
        _ task: String, prompt: String, schema: [String: Any], stamp: String, in library: RecordingLibrary
    ) async -> Data? {
        guard let kind = chosen else { return nil }
        let previous = calls
        let schemaText = String(
            decoding: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data(), as: UTF8.self)
        let model = testingModel ?? Self.setting("Model", for: kind)
        let effort = Self.setting("Effort", for: kind)
        let call = Task { () -> Result<Data?, AgentFailure> in
            await previous?.value
            guard self.chosen == kind else { return .success(nil) }
            let state = await AgentRunner.state(kind)
            self.states[kind] = state
            guard state == .signedIn else { return .failure(AgentFailure("\(kind.name) is not signed in")) }
            do {
                return .success(
                    try await AgentRunner.ask(kind, prompt: prompt, schema: schemaText, model: model, effort: effort))
            } catch let first {
                guard self.chosen == kind else { return .success(nil) }
                do {
                    return .success(try await AgentRunner.ask(kind, prompt: prompt, schema: schemaText, tuned: false))
                } catch {
                    guard self.chosen == kind else { return .success(nil) }
                    let reasons = [first, error].map { ($0 as? AgentFailure)?.reason ?? $0.localizedDescription }
                    return .failure(AgentFailure(reasons.joined(separator: "; then, with the user's settings: ")))
                }
            }
        }
        calls = Task { _ = await call.value }
        switch await call.value {
        case .success(let answer):
            return answer
        case .failure(let failure):
            // Looked up now: the folder may have been renamed during the call.
            if let folder = library.folder(withStamp: stamp) {
                EventLog.append(
                    "agent failed", ["agent": kind.rawValue, "task": task, "reason": failure.reason], in: folder)
            }
            return nil
        }
    }
}

struct AgentFailure: Error, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Finds and runs the agents' own commands. An app opened from Finder has
/// none of the shell's PATH, so the user's login shell is asked first, then
/// the usual install places are searched; what is found is kept.
enum AgentRunner {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [AgentKind: URL] = [:]

    /// Where the last search found it, without searching again.
    static func found(_ kind: AgentKind) -> URL? { lock.withLock { cache[kind] } }

    /// For the UI test: a stand-in command that fails like a signed-out agent.
    nonisolated(unsafe) static var testingBinary: URL?

    static func locate(_ kind: AgentKind) async -> URL? {
        if let testingBinary { return testingBinary }
        if let known = found(kind), FileManager.default.isExecutableFile(atPath: known.path) { return known }
        var url = await fromShell(kind)
        if url == nil { url = inUsualPlaces(kind) }
        lock.withLock { cache[kind] = url }
        return url
    }

    private static func inUsualPlaces(_ kind: AgentKind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var places = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
        places += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        for place in places {
            let path = "\(place)/\(kind.rawValue)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// The path the user's own shell would run, aliases left out.
    private static func fromShell(_ kind: AgentKind) async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let ask =
            shell.hasSuffix("zsh")
            ? "whence -p \(kind.rawValue)"
            : shell.hasSuffix("bash") ? "type -P \(kind.rawValue)" : "command -v \(kind.rawValue)"
        guard let output = try? await Run.run(URL(fileURLWithPath: shell), ["-lic", ask], timeout: 8) else {
            return nil
        }
        let path = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
            ? URL(fileURLWithPath: path) : nil
    }

    /// Signed in or not, from the tool's own status command. Codex's
    /// answer is judged by its exit status alone: its text can show part
    /// of an API key.
    static func state(_ kind: AgentKind) async -> AgentState {
        guard let binary = await locate(kind) else { return .notInstalled }
        switch kind {
        case .claude:
            guard let output = try? await Run.run(binary, ["auth", "status"], timeout: 15),
                let status = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]
            else { return .signedOut }
            return status["loggedIn"] as? Bool == true ? .signedIn : .signedOut
        case .codex:
            guard let output = try? await Run.run(binary, ["login", "status"], timeout: 15, keepOutput: false)
            else { return .signedOut }
            return output.status == 0 ? .signedIn : .signedOut
        }
    }

    /// Codex features that give the model tools, turned off for every
    /// call, with MCP servers and web search: the answer is text only.
    static let codexToolFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "remote_plugin", "multi_agent", "image_generation",
        "view_image", "browser_use", "browser_use_external", "computer_use", "memories", "skill_search",
        "in_app_browser", "in_app_local_automation", "code_mode_host", "tool_suggest", "chronicle",
    ]

    /// One call: the prompt on stdin, in an empty folder, no tools, the
    /// answer held to `schema`. With `tuned` false, the user's own model
    /// and settings decide, still without tools or hooks.
    static func ask(
        _ kind: AgentKind, prompt: String, schema: String, model: String? = nil, effort: String? = nil,
        tuned: Bool = true
    ) async throws -> Data {
        guard let binary = await locate(kind) else { throw AgentFailure("\(kind.name) is not installed") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        switch kind {
        case .claude:
            var arguments = [
                "-p", "--tools", "", "--output-format", "json", "--json-schema", schema,
                "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config",
            ]
            arguments +=
                tuned
                ? ["--model", model ?? "sonnet", "--effort", effort ?? "low", "--setting-sources", ""]
                : ["--settings", #"{"disableAllHooks":true}"#]
            let output = try await Run.run(binary, arguments, input: prompt, in: work, timeout: 120)
            // One result object, or every message when the user's settings ask for verbose output.
            let parsed = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
            let messages = parsed as? [[String: Any]] ?? (parsed as? [String: Any]).map { [$0] } ?? []
            guard let reply = messages.last(where: { $0["type"] as? String == "result" })
            else { throw AgentFailure(Self.reason(output)) }
            guard reply["is_error"] as? Bool != true, let answer = reply["structured_output"] as? [String: Any],
                let data = try? JSONSerialization.data(withJSONObject: answer)
            else { throw AgentFailure(reply["result"] as? String ?? Self.reason(output)) }
            return data
        case .codex:
            let schemaFile = work.appendingPathComponent("schema.json")
            let answerFile = work.appendingPathComponent("answer.json")
            try schema.write(to: schemaFile, atomically: true, encoding: .utf8)
            var arguments = [
                "exec", "-s", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never",
                "-c", "mcp_servers={}", "-c", #"web_search="disabled""#,
                "--output-schema", schemaFile.path, "-o", answerFile.path,
            ]
            arguments += codexToolFeatures.flatMap { ["--disable", $0] }
            if tuned {
                if let model { arguments += ["-m", model] }
                arguments += ["-c", "model_reasoning_effort=\(effort ?? "low")"]
            }
            let output = try await Run.run(binary, arguments + ["-"], input: prompt, in: work, timeout: 120)
            guard output.status == 0, let data = try? Data(contentsOf: answerFile),
                (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
            else { throw AgentFailure(Self.reason(output)) }
            return data
        }
    }

    private static func reason(_ output: Run.Output) -> String {
        let text = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let last = text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        return "exit \(output.status): \(last.prefix(300))"
    }
}

/// Runs a command to the end without holding a thread, its output in files
/// so a long one never fills a pipe, with the install place on PATH (a
/// Node-based agent needs `node` beside it). A command still running at
/// its time limit, or when the user withdraws the agent or quits, is
/// stopped, and killed if it does not stop.
enum Run {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<Process> = []

    /// Stops every command started here.
    static func stopAll() {
        for process in lock.withLock({ running }) { stop(process) }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    static func run(
        _ executable: URL, _ arguments: [String], input: String? = nil, in folder: URL? = nil,
        timeout: TimeInterval, keepOutput: Bool = true
    ) async throws -> Output {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("out")
        let err = scratch.appendingPathComponent("err")
        let inFile = scratch.appendingPathComponent("in")
        try Data((input ?? "").utf8).write(to: inFile)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder ?? scratch
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = [
            executable.resolvingSymlinksInPath().deletingLastPathComponent().path,
            executable.deletingLastPathComponent().path, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", environment["PATH"],
        ].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: inFile)
        process.standardOutput = keepOutput ? try FileHandle(forWritingTo: out) : FileHandle.nullDevice
        process.standardError = keepOutput ? try FileHandle(forWritingTo: err) : FileHandle.nullDevice
        let late = Flag()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in done.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                done.resume(throwing: error)
                return
            }
            lock.withLock { _ = running.insert(process) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                late.set()
                stop(process)
            }
        }
        lock.withLock { _ = running.remove(process) }
        if late.isSet { throw AgentFailure("no answer within \(Int(timeout)) s") }
        return Output(
            status: process.terminationStatus,
            stdout: keepOutput ? (try? String(contentsOf: out, encoding: .utf8)) ?? "" : "",
            stderr: keepOutput ? (try? String(contentsOf: err, encoding: .utf8)) ?? "" : "")
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

/// Opens Terminal on a command, so the user sees and answers it: a
/// `.command` file needs no permission to control Terminal, and removes
/// itself when it runs.
@MainActor
enum Terminal {
    static func run(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TapeUp-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\nrm -f \"$0\"\nclear\necho \(quote("TapeUp runs: \(command)"))\n\(command)\n"
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil,
            (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)) != nil,
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    nonisolated static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
