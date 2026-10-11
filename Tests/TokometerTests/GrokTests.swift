import XCTest
@testable import Tokometer

final class GrokTests: XCTestCase {
    private var home: URL!
    private var log: URL!
    private let now = Date().timeIntervalSince1970 * 1000   // ms

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString)")
        let session = home.appendingPathComponent("sessions/%2FUsers%2Fme%2Fproject/01a12aba-0000-7000-8000-000000000001")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        log = session.appendingPathComponent("updates.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func scanner() -> Tokometer.Scanner {
        let s = Tokometer.Scanner()
        s.grokHome = home
        return s
    }

    private func scan(_ s: Tokometer.Scanner) -> [Sample] {
        var out: [Sample] = []
        s.scanGrok(cutoff: Date().addingTimeInterval(-s.lookback), &out)
        return out
    }

    private func append(_ lines: [String]) throws {
        let text = lines.joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try h.close()
        } else {
            try text.write(to: log, atomically: true, encoding: .utf8)
        }
    }

    // Line shapes copied from a real Grok Build 1.0.50 session.
    private func userMessage(model: String) -> String {
        """
        {"timestamp": \(Int(now / 1000)), "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "fix the tests"}, "_meta": {"modelId": "\(model)", "promptIndex": 0}}, "_meta": {"eventId": "s1-4", "agentTimestampMs": \(Int(now - 20_000))}}}
        """
    }

    private func agentChunk() -> String {
        """
        {"timestamp": \(Int(now / 1000)), "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done."}}, "_meta": {"totalTokens": 1335, "eventId": "s1-17", "agentTimestampMs": \(Int(now - 1000)), "promptId": "p1", "updateType": "AgentMessageChunk", "chunkId": 12}}}
        """
    }

    private func turnCompleted(prompt: String, end: Double, models: [(String, Int, Int)]) -> String {
        let usage = models.map { m, out, ms in
            "\"\(m)\": {\"inputTokens\": 16378, \"outputTokens\": \(out), \"totalTokens\": \(16378 + out), \"cachedReadTokens\": 1664, \"cacheCreationTokens\": 0, \"reasoningTokens\": 30, \"modelCalls\": 3, \"apiDurationMs\": \(ms), \"costUsdTicks\": 103740800}"
        }.joined(separator: ", ")
        let out = models.reduce(0) { $0 + $1.1 }, ms = models.reduce(0) { $0 + $1.2 }
        return """
        {"timestamp": \(Int(end / 1000)), "method": "_x.ai/session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "turn_completed", "prompt_id": "\(prompt)", "stop_reason": "end_turn", "usage": {"inputTokens": 16378, "outputTokens": \(out), "totalTokens": \(16378 + out), "cachedReadTokens": 1664, "cacheCreationTokens": 0, "reasoningTokens": 30, "modelCalls": 3, "apiDurationMs": \(ms), "costUsdTicks": 103740800, "modelUsage": {\(usage)}}}, "_meta": {"eventId": "s1-22", "agentTimestampMs": \(Int(end))}}}
        """
    }

    func testTurnUsesAPITimeAndServedModel() throws {
        try append([userMessage(model: "grok-4.7"), agentChunk(),
                    turnCompleted(prompt: "p1", end: now, models: [("grok-4.7-build", 900, 10_000)])])
        let found = scan(scanner())
        XCTAssertEqual(found.count, 1)
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.source, .grok)
        XCTAssertEqual(s.model, "grok-4.7-build")
        XCTAssertEqual(s.requested, "grok-4.7")
        XCTAssertEqual(s.tokens, 900)                    // outputTokens already includes reasoning
        XCTAssertEqual(s.duration, 10, accuracy: 0.001)  // apiDurationMs, not wall clock with tools
        XCTAssertEqual(s.end, now / 1000, accuracy: 0.001)
    }

    func testOneSamplePerModelInATurn() throws {
        try append([userMessage(model: "grok-4.7"),
                    turnCompleted(prompt: "p1", end: now,
                                  models: [("grok-4.7-build", 900, 10_000), ("grok-4.7-mini", 400, 2_000)])])
        let found = scan(scanner()).sorted { $0.model < $1.model }
        XCTAssertEqual(found.map(\.model), ["grok-4.7-build", "grok-4.7-mini"])
        XCTAssertEqual(found.last?.tps ?? 0, 200, accuracy: 0.001)
    }

    func testReadsOnlyNewTurnsAndSkipsShortOnes() throws {
        let s = scanner()
        try append([userMessage(model: "grok-4.7"),
                    turnCompleted(prompt: "p1", end: now - 5_000, models: [("grok-4.7-build", 42, 1_684)])])
        XCTAssertTrue(scan(s).isEmpty, "42 tokens is below the 200-token minimum")

        try append([turnCompleted(prompt: "p2", end: now, models: [("grok-4.7-build", 600, 6_000)])])
        let found = scan(s)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tps ?? 0, 100, accuracy: 0.001)
        XCTAssertTrue(scan(s).isEmpty, "unchanged log isn't read again")
    }

    func testIgnoresOtherSessionFiles() throws {
        let other = log.deletingLastPathComponent().appendingPathComponent("chat_history.jsonl")
        try turnCompleted(prompt: "p1", end: now, models: [("grok-4.7-build", 900, 10_000)])
            .write(to: other, atomically: true, encoding: .utf8)
        XCTAssertTrue(scan(scanner()).isEmpty)
    }
}
