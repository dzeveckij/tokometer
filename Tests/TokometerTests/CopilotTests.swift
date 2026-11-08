import XCTest
@testable import Tokometer

final class CopilotTests: XCTestCase {
    private var home: URL!
    private let now = (Date().timeIntervalSince1970 * 1000).rounded()   // ms

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("session-state/s1"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func scanner() -> Tokometer.Scanner {
        let s = Tokometer.Scanner()
        s.copilotHome = home
        return s
    }

    private func scan(_ s: Tokometer.Scanner) -> [Sample] {
        var out: [Sample] = []
        s.scanCopilot(cutoff: Date().addingTimeInterval(-s.lookback), &out)
        return out
    }

    private func log(_ session: String = "s1") -> URL {
        home.appendingPathComponent("session-state/\(session)/events.jsonl")
    }

    private func write(_ lines: [String], session: String = "s1", append: Bool = false) throws {
        let url = log(session), text = lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append, let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try h.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func iso(_ ms: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // Line shape copied from real Copilot CLI 1.0.100 sessions.
    private func usage(id: String, end: Double, output: Int, ms: Int, model: String = "gpt-5.6-luna",
                       provider: String = "openai", byok: Bool = false) -> String {
        """
        {"type":"session.usage_record","data":{"usage":{"model":"\(model)","provider":"\(provider)","modelDisplayName":"GPT","inputTokens":12869,"outputTokens":\(output),"cacheReadTokens":0,"cacheWriteTokens":12866,"reasoningTokens":11,"duration":\(ms),"timeToFirstTokenMs":1220.8,"initiator":"user","isByok":\(byok),"isAuto":false,"accounting":{"sourceSessionId":"s1","sequence":1,"usageId":"\(id)"},"reasoningEffort":"medium","finishReason":"stop"}},"id":"e-\(id)","timestamp":"\(iso(end))","parentId":"p"}
        """
    }

    private let other = #"{"type":"assistant.message","data":{"model":"gpt-5.6-luna","content":"session.usage_record"},"id":"m1","timestamp":"2026-10-19T21:51:34.489Z"}"#

    func testUsesCallDurationAndOutputTokens() throws {
        try write([other, usage(id: "u1", end: now, output: 800, ms: 4_000)])
        let found = scan(scanner())
        XCTAssertEqual(found.count, 1)
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.source, .copilot)
        XCTAssertEqual(s.model, "gpt-5.6-luna")
        XCTAssertEqual(s.tokens, 800)
        XCTAssertEqual(s.duration, 4, accuracy: 0.001)
        XCTAssertEqual(s.tps, 200, accuracy: 0.001)
        XCTAssertEqual(s.end, now / 1000, accuracy: 0.01)
    }

    func testOwnKeyKeepsProviderInLabel() throws {
        try write([usage(id: "u1", end: now, output: 800, ms: 4_000, model: "kimi-k3", provider: "fireworks", byok: true)])
        XCTAssertEqual(scan(scanner()).first?.model, "fireworks/kimi-k3")
    }

    func testForkedSessionsCountACallOnce() throws {
        let line = usage(id: "u1", end: now, output: 800, ms: 4_000)
        try write([line])
        try write([line], session: "fork")
        XCTAssertEqual(scan(scanner()).count, 1)
    }

    func testReadsOnlyNewCallsAndSkipsShortOnes() throws {
        let s = scanner()
        try write([usage(id: "u1", end: now - 5_000, output: 29, ms: 1_000)])
        XCTAssertTrue(scan(s).isEmpty, "below the 200-token minimum")
        try write([usage(id: "u2", end: now, output: 600, ms: 3_000)], append: true)
        XCTAssertEqual(scan(s).map(\.tokens), [600])
        XCTAssertTrue(scan(s).isEmpty)
    }

    func testIgnoresOtherEvents() throws {
        try write([other])
        XCTAssertTrue(scan(scanner()).isEmpty)
    }
}
