import Foundation
import Testing
@testable import ClaudeSwitcherCore

private struct LiveUsageExecutableFixture {
    let directory: URL
    let executable: URL
    let arguments: URL
    let environment: URL
    let input: URL
    let authLog: URL
}

private func liveUsageShellLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func makeLiveUsageExecutableFixture(
    beforeEmail: String,
    afterEmail: String
) throws -> LiveUsageExecutableFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-switcher-live-usage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("fake-claude", isDirectory: false)
    let arguments = directory.appendingPathComponent("usage-arguments.txt", isDirectory: false)
    let environment = directory.appendingPathComponent("usage-environment.txt", isDirectory: false)
    let input = directory.appendingPathComponent("usage-input.jsonl", isDirectory: false)
    let authLog = directory.appendingPathComponent("auth-emails.txt", isDirectory: false)
    let marker = directory.appendingPathComponent("first-auth-finished", isDirectory: false)
    let script = """
    #!/bin/sh
    if test "$1" = "auth"; then
      if test -f \(liveUsageShellLiteral(marker.path)); then
        email=\(liveUsageShellLiteral(afterEmail))
      else
        email=\(liveUsageShellLiteral(beforeEmail))
        /usr/bin/touch \(liveUsageShellLiteral(marker.path))
      fi
      /usr/bin/printf '%s\n' "$email" >> \(liveUsageShellLiteral(authLog.path))
      /usr/bin/printf '{"loggedIn":true,"authMethod":"claude.ai","email":"%s","subscriptionType":"max"}' "$email"
      exit 0
    fi
    /usr/bin/printf '%s\n' "$@" > \(liveUsageShellLiteral(arguments.path))
    /usr/bin/env > \(liveUsageShellLiteral(environment.path))
    /bin/cat > \(liveUsageShellLiteral(input.path))
    /usr/bin/printf '%s\n' '{"type":"control_response","response":{"request_id":"claude-switcher-usage","subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":21,"resets_at":null},"seven_day":{"utilization":48,"resets_at":null}}}}}'
    """
    try Data(script.utf8).write(to: executable, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return LiveUsageExecutableFixture(
        directory: directory,
        executable: executable,
        arguments: arguments,
        environment: environment,
        input: input,
        authLog: authLog
    )
}

struct LiveUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func requireLiveUsageError(
        _ expected: LiveUsageError,
        operation: () throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected) to be thrown", sourceLocation: sourceLocation)
        } catch let error as LiveUsageError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected LiveUsageError, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("Fractional ISO reset dates are preserved")
    func fractionalISOResetDateDecodes() throws {
        let snapshot = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":12.5,"resets_at":"2026-09-27T01:02:03.456Z"}}"#), email: "person@example.com", now: now)
        let reset = try #require(snapshot.fiveHour?.resetsAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try #require(formatter.date(from: "2026-09-27T01:02:03.456Z"))

        #expect(reset == expected)
        #expect(snapshot.fiveHour?.percent == 12.5)
    }

    @Test("Zero utilization with a null reset is a real reading")
    func zeroWithNullResetIsValid() throws {
        let snapshot = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":0,"resets_at":null}}"#), email: "person@example.com", now: now)
        let window = try #require(snapshot.fiveHour)

        #expect(window.percent == 0)
        #expect(window.resetsAt == nil)
        #expect(window.displayedPercent(at: now) == 0)
    }

    @Test("Missing and malformed windows remain unknown")
    func invalidOrMissingWindowsRemainNil() throws {
        let snapshot = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":"0","resets_at":null},"seven_day":null}"#), email: "person@example.com", now: now)

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay == nil)
    }

    @Test("A response without either usage window is unavailable")
    func responseMissingUsageWindowsIsUnavailable() {
        requireLiveUsageError(.unavailable) {
            _ = try LiveUsageSnapshot.decode(self.data(#"{"message":"ok"}"#), email: "person@example.com", now: self.now)
        }
    }

    @Test("Utilization accepts both inclusive percentage bounds")
    func percentageBoundsAreAccepted() throws {
        let snapshot = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":100,"resets_at":null}}"#), email: "person@example.com", now: now)

        #expect(snapshot.fiveHour?.percent == 0)
        #expect(snapshot.sevenDay?.percent == 100)
    }

    @Test("Out-of-range percentages and booleans are rejected")
    func invalidPercentagesAreRejected() throws {
        let below = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":-0.01}}"#), email: "a", now: now)
        let above = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":100.01}}"#), email: "a", now: now)
        let boolean = try LiveUsageSnapshot.decode(data(#"{"five_hour":{"utilization":true}}"#), email: "a", now: now)

        #expect(below.fiveHour == nil)
        #expect(above.fiveHour == nil)
        #expect(boolean.fiveHour == nil)
    }

    @Test("An elapsed reset makes the displayed percentage unknown")
    func expiredResetDisplaysUnknown() {
        let window = LiveUsageWindow(percent: 73.6, resetsAt: now)

        #expect(window.displayedPercent(at: now.addingTimeInterval(-1)) == 74)
        #expect(window.displayedPercent(at: now) == nil)
        #expect(window.displayedPercent(at: now.addingTimeInterval(1)) == nil)
    }

    @Test("The matching usage control response is decoded among unrelated output")
    func decodeResponseSelectsMatchingRequestID() throws {
        let output = data("""
        startup noise that is not JSON
        {"type":"control_response","response":{"request_id":"another-request","subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":99}}}}}
        {"type":"system","subtype":"init"}
        {"type":"control_response","response":{"request_id":"claude-switcher-usage","subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":34.5,"resets_at":null},"seven_day":{"utilization":67,"resets_at":null}}}}}
        """)

        let snapshot = try LiveUsageReader.decodeResponse(output, email: "person@example.com", now: now)

        #expect(snapshot.email == "person@example.com")
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.fiveHour?.percent == 34.5)
        #expect(snapshot.sevenDay?.percent == 67)
    }

    /// What Claude Code 2.1.326 returns for a plan without a five-hour limit, cut to the keys read.
    static let weeklyAndModelPayload = #"""
    {"five_hour":null,
     "seven_day":{"utilization":82,"resets_at":"2026-11-20T07:00:00.120426+00:00","limit_dollars":null},
     "seven_day_opus":null,"seven_day_sonnet":null,
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":0,"utilization":null},
     "limits":[
      {"kind":"weekly_all","group":"weekly","percent":82,"severity":"normal","resets_at":"2026-11-20T07:00:00.120426+00:00","scope":null,"is_active":true},
      {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"normal","resets_at":"2026-11-20T07:00:00.120580+00:00",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],
     "weekly_scoped_shares":[{"limit_index":1,"used_percent_of_weekly":41,"allowance_percent_of_weekly":50}],
     "model_scoped":[{"display_name":"Fable","utilization":100,"resets_at":"2026-11-20T07:00:00.120580+00:00"}]}
    """#

    @Test("A model's own weekly limit is read beside the week, and a missing five-hour limit stays absent")
    func modelLimitIsReadWithoutAFiveHourWindow() throws {
        let snapshot = try LiveUsageSnapshot.decode(data(Self.weeklyAndModelPayload), email: "person@example.com", now: now)

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.sevenDay?.percent == 82)
        #expect(snapshot.models.map(\.name) == ["Fable"])
        #expect(snapshot.models.first?.window.percent == 100)
        let reset = try #require(snapshot.models.first?.window.resetsAt)
        #expect(snapshot.windows.count == 2)
        // The reading is refreshed when the model's limit resets, not only the week's.
        let justBefore = reset.addingTimeInterval(-30)
        let reread = LiveUsageSnapshot(email: "a", fetchedAt: justBefore, fiveHour: nil, sevenDay: nil, models: snapshot.models)
        #expect(LiveUsagePolicy.nextRefresh(for: reread, now: justBefore) == reset)
    }

    @Test("Model limits are found in either list Claude sends, once each")
    func modelLimitsComeFromEitherList() throws {
        let older = try LiveUsageSnapshot.decode(data(#"{"seven_day":{"utilization":10},"model_scoped":[{"display_name":"Fable","utilization":40,"resets_at":null},{"display_name":"fable","utilization":50}]}"#), email: "a", now: now)
        #expect(older.models == [LiveUsageModelWindow(name: "Fable", window: LiveUsageWindow(percent: 40, resetsAt: nil))])

        let both = try LiveUsageSnapshot.decode(data(#"{"seven_day":{"utilization":10},"limits":[{"kind":"weekly_scoped","percent":70,"scope":{"model":{"display_name":"Fable"}}}],"model_scoped":[{"display_name":"Fable","utilization":40},{"display_name":"Opus","utilization":5}]}"#), email: "a", now: now)
        #expect(both.models.map(\.name) == ["Fable"])
        #expect(both.models.first?.window.percent == 70)
    }

    @Test("Limits that name no model, or carry no usable figure, are not model limits")
    func unusableModelLimitsAreLeftOut() throws {
        let long = String(repeating: "x", count: 25)
        let snapshot = try LiveUsageSnapshot.decode(data(#"{"seven_day":{"utilization":10},"limits":[{"kind":"weekly_all","percent":10,"scope":null},{"kind":"weekly_scoped","percent":30,"scope":{"model":null,"surface":"cowork"}},{"percent":"30","scope":{"model":{"display_name":"Text"}}},{"percent":130,"scope":{"model":{"display_name":"Over"}}},{"percent":true,"scope":{"model":{"display_name":"Flag"}}},{"percent":30,"scope":{"model":{"display_name":"  "}}},{"percent":30,"scope":{"model":{"display_name":"\#(long)"}}},{"percent":30,"resets_at":"soon","scope":{"model":{"display_name":"BadDate"}}},"noise",{"percent":30,"scope":{"model":{"display_name":" Opus "}}}]}"#), email: "a", now: now)

        #expect(snapshot.models == [LiveUsageModelWindow(name: "Opus", window: LiveUsageWindow(percent: 30, resetsAt: nil))])
    }

    @Test("The week is still read if only the limits list carries it")
    func weekFallsBackToTheLimitsList() throws {
        let snapshot = try LiveUsageSnapshot.decode(data(#"{"five_hour":null,"seven_day":null,"limits":[{"kind":"weekly_all","percent":64,"resets_at":"2026-11-20T07:00:00Z","scope":null}]}"#), email: "a", now: now)
        #expect(snapshot.sevenDay?.percent == 64)
        #expect(snapshot.sevenDay?.resetsAt != nil)

        let withoutLegacyKeys = try LiveUsageSnapshot.decode(data(#"{"limits":[{"kind":"session","percent":31,"scope":null},{"kind":"weekly_all","percent":7,"scope":null},{"kind":"weekly_scoped","percent":50,"scope":{"model":{"id":"claude-fable-5-2","display_name":null}}}]}"#), email: "a", now: now)
        #expect(withoutLegacyKeys.fiveHour?.percent == 31)
        #expect(withoutLegacyKeys.sevenDay?.percent == 7)
        // A model known only by its id still gets its gauge.
        #expect(withoutLegacyKeys.models.map(\.name) == ["claude-fable-5-2"])
        // The legacy figure wins while it is sent.
        let legacy = try LiveUsageSnapshot.decode(data(#"{"seven_day":{"utilization":20},"limits":[{"kind":"weekly_all","percent":64,"scope":null}]}"#), email: "a", now: now)
        #expect(legacy.sevenDay?.percent == 20)
    }

    @Test("A reading saved before model limits existed still loads")
    func aSavedReadingWithoutModelsDecodes() throws {
        let saved = LiveUsageSnapshot(email: "person@example.com", fetchedAt: now, fiveHour: nil,
                                      sevenDay: LiveUsageWindow(percent: 64, resetsAt: now.addingTimeInterval(86400)),
                                      models: [LiveUsageModelWindow(name: "Fable", window: LiveUsageWindow(percent: 30, resetsAt: nil))])
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(LiveUsageSnapshot.self, from: encoded) == saved)

        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "models")
        let older = try JSONDecoder().decode(LiveUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.sevenDay == saved.sevenDay)
        #expect(older.models.isEmpty)
    }

    @Test("A matching failure control response is unavailable")
    func decodeResponseRejectsFailureSubtype() {
        let output = data(#"{"type":"control_response","response":{"request_id":"claude-switcher-usage","subtype":"error","error":"usage failed"}}"#)

        requireLiveUsageError(.unavailable) {
            _ = try LiveUsageReader.decodeResponse(output, email: "person@example.com", now: now)
        }
    }

    @Test("Null or missing rate limits are unavailable")
    func decodeResponseRejectsAbsentRateLimits() {
        let outputs = [
            #"{"type":"control_response","response":{"request_id":"claude-switcher-usage","subtype":"success","response":{"rate_limits_available":true,"rate_limits":null}}}"#,
            #"{"type":"control_response","response":{"request_id":"claude-switcher-usage","subtype":"success","response":{"rate_limits_available":true}}}"#,
            #"{"type":"control_response","response":{"request_id":"claude-switcher-usage","subtype":"success","response":{"rate_limits_available":false,"rate_limits":{}}}}"#,
        ]

        for output in outputs {
            requireLiveUsageError(.unavailable) {
                _ = try LiveUsageReader.decodeResponse(self.data(output), email: "person@example.com", now: self.now)
            }
        }
    }

    @Test("Stream output over two MiB is unavailable")
    func decodeResponseRejectsOversizedOutput() {
        let output = Data(repeating: 0x20, count: 2_097_153)

        requireLiveUsageError(.unavailable) {
            _ = try LiveUsageReader.decodeResponse(output, email: "person@example.com", now: now)
        }
    }

    @Test("Reader uses isolated authentication and the restricted stream-json protocol")
    func readerUsesSafeCLIProtocolAndEnvironment() throws {
        let fixture = try makeLiveUsageExecutableFixture(
            beforeEmail: "Person@Example.COM",
            afterEmail: "Person@Example.COM"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let credentialDirectory = fixture.directory.appendingPathComponent("isolated credentials", isDirectory: true).path
        let profile = Profile(id: "work", label: "Work", credDir: credentialDirectory)
        let inherited: [String: String] = [
            "HOME": fixture.directory.path,
            "PATH": "/usr/bin:/bin",
            "KEEP_ME": "preserved",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "CLAUDE_CODE_OAUTH_TOKEN": "must-not-leak",
            "ANTHROPIC_API_KEY": "must-not-leak",
        ]

        let snapshot = try LiveUsageReader.read(
            profile: profile,
            email: "person@example.com",
            executable: fixture.executable.path,
            timeout: 2,
            baseEnvironment: inherited
        )

        #expect(snapshot.email == "person@example.com")
        #expect(snapshot.fiveHour?.percent == 21)
        #expect(snapshot.sevenDay?.percent == 48)

        let arguments = try String(contentsOf: fixture.arguments, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        #expect(arguments == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
            "--no-session-persistence", "--no-chrome", "--disable-slash-commands",
        ])

        let inputLines = try String(contentsOf: fixture.input, encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(inputLines.count == 2)
        let initialize = try #require(inputLines.first)
        let initializeRequest = try #require(initialize["request"] as? [String: Any])
        #expect(initialize["type"] as? String == "control_request")
        #expect(initialize["request_id"] as? String == "claude-switcher-init")
        #expect(initializeRequest["subtype"] as? String == "initialize")
        let usage = try #require(inputLines.last)
        let usageRequest = try #require(usage["request"] as? [String: Any])
        #expect(usage["type"] as? String == "control_request")
        #expect(usage["request_id"] as? String == LiveUsageReader.requestID)
        #expect(usageRequest["subtype"] as? String == "get_usage")
        #expect(usageRequest["skip_behaviors"] as? Bool == true)

        let environment = Dictionary(uniqueKeysWithValues: try String(contentsOf: fixture.environment, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
        #expect(environment["CLAUDE_CONFIG_DIR"] == credentialDirectory)
        #expect(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == credentialDirectory)
        #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
        #expect(environment["CLAUDE_CODE_ENABLE_TELEMETRY"] == nil)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["DISABLE_TELEMETRY"] == "1")
        #expect(environment["DISABLE_ERROR_REPORTING"] == "1")
        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(environment["KEEP_ME"] == "preserved")

        let checkedEmails = try String(contentsOf: fixture.authLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(checkedEmails == ["Person@Example.COM", "Person@Example.COM"])
    }

    @Test("Reader rejects an account that changes after usage is fetched")
    func readerRejectsChangedIdentity() throws {
        let fixture = try makeLiveUsageExecutableFixture(
            beforeEmail: "person@example.com",
            afterEmail: "different@example.com"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let profile = Profile(
            id: "work",
            label: "Work",
            credDir: fixture.directory.appendingPathComponent("credentials", isDirectory: true).path
        )

        requireLiveUsageError(.accountMismatch) {
            _ = try LiveUsageReader.read(
                profile: profile,
                email: "person@example.com",
                executable: fixture.executable.path,
                timeout: 2,
                baseEnvironment: ["HOME": fixture.directory.path, "PATH": "/usr/bin:/bin"]
            )
        }

        let checkedEmails = try String(contentsOf: fixture.authLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(checkedEmails == ["person@example.com", "different@example.com"])
    }

    @Test("An unrelated response cannot supply account usage")
    func unrelatedAndMalformedResponsesAreUnavailable() {
        for output in ["not JSON", #"{"type":"control_response","response":{"request_id":"other","subtype":"success"}}"#] {
            requireLiveUsageError(.unavailable) {
                _ = try LiveUsageReader.decodeResponse(data(output), email: "person@example.com", now: now)
            }
        }
    }

    @Test("A wrong initial account prevents the usage request")
    func initialIdentityMismatchDoesNotLaunchUsage() throws {
        let fixture = try makeLiveUsageExecutableFixture(beforeEmail: "wrong@example.com", afterEmail: "person@example.com")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        requireLiveUsageError(.accountMismatch) {
            _ = try LiveUsageReader.read(profile: Profile(id: "work", label: "Work"), email: "person@example.com",
                                         executable: fixture.executable.path,
                                         baseEnvironment: ["HOME": fixture.directory.path, "PATH": "/usr/bin:/bin"])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.arguments.path))
    }

    @Test("A stuck usage subprocess is bounded by its timeout")
    func readerTimeoutIsBounded() throws {
        let fixture = try makeLiveUsageExecutableFixture(beforeEmail: "person@example.com", afterEmail: "person@example.com")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let script = """
        #!/bin/sh
        if test "$1" = "auth"; then
          /usr/bin/printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com"}'
          exit 0
        fi
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to: fixture.executable)
        let started = Date()
        requireLiveUsageError(.unavailable) {
            _ = try LiveUsageReader.read(profile: Profile(id: "work", label: "Work"), email: "person@example.com",
                                         executable: fixture.executable.path, timeout: 0.1,
                                         baseEnvironment: ["HOME": fixture.directory.path, "PATH": "/usr/bin:/bin"])
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
