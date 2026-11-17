import Foundation
import Darwin

public struct LiveUsageWindow: Codable, Equatable, Sendable {
    public let percent: Double
    public let resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// An elapsed window is unknown until the server returns a new reading.
    public func displayedPercent(at now: Date) -> Int? {
        guard resetsAt.map({ $0 > now }) ?? true else { return nil }
        return Int(min(100, max(0, percent)).rounded())
    }
}

/// A weekly limit that applies to one model, such as Fable.
public struct LiveUsageModelWindow: Codable, Equatable, Sendable {
    public let name: String
    public let window: LiveUsageWindow

    public init(name: String, window: LiveUsageWindow) {
        self.name = name
        self.window = window
    }
}

public struct LiveUsageSnapshot: Codable, Equatable, Sendable {
    public let email: String
    public let fetchedAt: Date
    /// `nil` when the account has no five-hour limit, as on a verified Ultra plan.
    public let fiveHour: LiveUsageWindow?
    public let sevenDay: LiveUsageWindow?
    /// Weekly limits for single models, in the order the account reports them. Such a limit
    /// can fill while the week for all models still has room.
    public let models: [LiveUsageModelWindow]

    public init(email: String, fetchedAt: Date, fiveHour: LiveUsageWindow?, sevenDay: LiveUsageWindow?,
                models: [LiveUsageModelWindow] = []) {
        self.email = email
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = models
    }

    /// Readings saved before model limits existed have no `models`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        fiveHour = try container.decodeIfPresent(LiveUsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(LiveUsageWindow.self, forKey: .sevenDay)
        models = (try? container.decodeIfPresent([LiveUsageModelWindow].self, forKey: .models)) ?? []
    }

    /// Every limit that can stop work on this account, each with the moment it resets.
    public var windows: [LiveUsageWindow] {
        [fiveHour, sevenDay].compactMap { $0 } + models.map(\.window)
    }

    /// Longest model name kept: it is a gauge label, not free text.
    static let maximumModelNameLength = 24

    /// Model limits as the app shows them: named, one per model, and where a model is
    /// listed twice the fuller figure, which is the one that stops work first.
    static func modelWindows(_ candidates: [(name: String?, window: LiveUsageWindow?)]) -> [LiveUsageModelWindow] {
        var models: [LiveUsageModelWindow] = []
        for candidate in candidates {
            guard let name = candidate.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  name.count <= maximumModelNameLength, let window = candidate.window else { continue }
            if let index = models.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if window.percent > models[index].window.percent {
                    models[index] = LiveUsageModelWindow(name: models[index].name, window: window)
                }
            } else {
                models.append(LiveUsageModelWindow(name: name, window: window))
            }
        }
        return models
    }

    /// Reads Claude's usage payload, as the account engine does (`build_usage_result`). The
    /// five-hour and all-models windows come from `five_hour` and `seven_day`, or from their
    /// `limits` entries (`session`, `weekly_all`) when those keys are unusable. Each model's
    /// weekly limit is an entry of `limits` that names a model, with `model_scoped` as the
    /// same list in another form.
    public static func decode(_ data: Data, email: String, now: Date) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.keys.contains("five_hour") || root.keys.contains("seven_day") || root["limits"] is [Any] else {
            throw LiveUsageError.unavailable
        }
        func window(_ value: Any?, percent key: String) -> LiveUsageWindow? {
            guard let value = value as? [String: Any],
                  let percent = value[key] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(), percent.doubleValue.isFinite,
                  (0...100).contains(percent.doubleValue) else { return nil }
            var reset: Date?
            if let text = value["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
                guard reset != nil else { return nil }
            } else if value["resets_at"] != nil, !(value["resets_at"] is NSNull) { return nil }
            return LiveUsageWindow(percent: percent.doubleValue, resetsAt: reset)
        }
        let limits = (root["limits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var models = modelWindows(limits.map { limit in
            let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model?["id"] as? String
            return (name, window(limit, percent: "percent"))
        })
        if models.isEmpty {
            models = modelWindows((root["model_scoped"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map {
                ($0["display_name"] as? String, window($0, percent: "utilization"))
            })
        }
        // A plan without a five-hour limit sends neither `five_hour` nor a `session` entry.
        func legacy(_ key: String, orLimit kind: String) -> LiveUsageWindow? {
            window(root[key], percent: "utilization")
                ?? limits.first { $0["kind"] as? String == kind }.flatMap { window($0, percent: "percent") }
        }
        return Self(email: email, fetchedAt: now, fiveHour: legacy("five_hour", orLimit: "session"),
                    sevenDay: legacy("seven_day", orLimit: "weekly_all"), models: models)
    }
}

public enum LiveUsageError: Error, Equatable, Sendable {
    case accountMismatch
    case unavailable
}

public enum LiveUsagePolicy {
    public static let refreshInterval: TimeInterval = 300
    /// Accounts refresh at different moments, so a reading counts as stale only well past one
    /// refresh cycle. Stale readings keep their colours and are shown as approximate.
    public static let staleAfter: TimeInterval = 20 * 60
    public static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let failureBackoff: TimeInterval = 900

    /// No reading, a failed refresh, or a reading older than `staleAfter`.
    public static func isStale(_ snapshot: LiveUsageSnapshot?, failed: Bool, now: Date) -> Bool {
        guard let snapshot, !failed else { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) > staleAfter
    }

    public static func nextRefresh(for snapshot: LiveUsageSnapshot, now: Date) -> Date {
        let reset = snapshot.windows.compactMap(\.resetsAt).filter { $0 > now }.min() ?? .distantFuture
        return min(snapshot.fetchedAt.addingTimeInterval(refreshInterval), reset)
    }
}

/// Uses Claude Code's structured /usage control request. No model prompt, token access,
/// hooks, tools, MCP servers, or transcript scan. The CLI owns authentication and refresh.
public enum LiveUsageReader {
    public static let requestID = "claude-switcher-usage"

    public static func decodeResponse(_ data: Data, email: String, now: Date) throws -> LiveUsageSnapshot {
        guard data.count <= 2_097_152 else { throw LiveUsageError.unavailable }
        for line in data.split(separator: 10) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else { continue }
            guard response["subtype"] as? String == "success",
                  let payload = response["response"] as? [String: Any],
                  payload["rate_limits_available"] as? Bool == true,
                  let limits = payload["rate_limits"] as? [String: Any] else { throw LiveUsageError.unavailable }
            return try LiveUsageSnapshot.decode(JSONSerialization.data(withJSONObject: limits), email: email, now: now)
        }
        throw LiveUsageError.unavailable
    }

    public static func read(profile: Profile, email: String, executable: String?, timeout: TimeInterval = 15,
                            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> LiveUsageSnapshot {
        guard let executable else { throw LiveUsageError.unavailable }
        let before = AccountStatusReader.read(profile: profile, executable: executable, baseEnvironment: baseEnvironment)
        guard before != .unavailable else { throw LiveUsageError.unavailable }
        guard before.matches(email) else { throw LiveUsageError.accountMismatch }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.jsonl")
        let outputURL = directory.appendingPathComponent("output.jsonl")
        let requests: [[String: Any]] = [
            ["type": "control_request", "request_id": "claude-switcher-init", "request": ["subtype": "initialize"]],
            ["type": "control_request", "request_id": requestID, "request": ["subtype": "get_usage", "skip_behaviors": true]],
        ]
        var inputData = Data()
        for request in requests {
            inputData.append(try JSONSerialization.data(withJSONObject: request))
            inputData.append(10)
        }
        guard fm.createFile(atPath: inputURL.path, contents: inputData, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LiveUsageError.unavailable
        }
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                             "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                             "--no-session-persistence", "--no-chrome", "--disable-slash-commands"]
        var environment = LaunchPlanning.terminalEnvironment(for: profile, inheriting: baseEnvironment)
        // The broad traffic switch disables /usage itself; keep telemetry separately disabled.
        environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        environment.removeValue(forKey: "CLAUDE_CODE_ENABLE_TELEMETRY")
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            throw LiveUsageError.unavailable
        }
        guard process.terminationStatus == 0 else { throw LiveUsageError.unavailable }
        let after = AccountStatusReader.read(profile: profile, executable: executable, baseEnvironment: baseEnvironment)
        guard after != .unavailable else { throw LiveUsageError.unavailable }
        guard after.matches(email) else { throw LiveUsageError.accountMismatch }
        return try decodeResponse(Data(contentsOf: outputURL), email: email, now: Date())
    }
}
