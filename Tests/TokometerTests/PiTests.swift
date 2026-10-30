import XCTest
@testable import Tokometer

final class PiTests: XCTestCase {
    private var root: URL!
    private let now = (Date().timeIntervalSince1970 * 1000).rounded()   // ms

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        for agent in ["pi", "omp"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("\(agent)/sessions/-Users-me-project"), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func scanner() -> Tokometer.Scanner {
        let s = Tokometer.Scanner()
        s.piDir = root.appendingPathComponent("pi")
        s.ompDir = root.appendingPathComponent("omp")
        return s
    }

    private func scan(_ s: Tokometer.Scanner) -> [Sample] {
        var out: [Sample] = []
        s.scanPiAgents(cutoff: Date().addingTimeInterval(-s.lookback), &out)
        return out
    }

    private func session(_ agent: String, _ name: String = "2026-10-30T11-24-57-584Z_s1.jsonl") -> URL {
        root.appendingPathComponent("\(agent)/sessions/-Users-me-project/\(name)")
    }

    private func write(_ url: URL, _ lines: [String], append: Bool = false) throws {
        let text = lines.joined(separator: "\n") + "\n"
        if append, let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try h.close()
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func isoTime(_ ms: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    // Line shapes copied from real pi 1.1.0 / OMP 18.14.0 sessions.
    private func piAssistant(id: String, start: Double, end: Double, output: Int, stop: String = "toolUse",
                             responseId: String? = nil) -> String {
        """
        {"type":"message","id":"\(id)","parentId":"p0","timestamp":"\(isoTime(end))","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"api":"openai-responses","provider":"openai","model":"gpt-6.1-sol","usage":{"input":5526,"output":\(output),"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":\(5526 + output)},"stopReason":"\(stop)","timestamp":\(Int(start))\(responseId.map { ",\"responseId\":\"\($0)\"" } ?? ""),"thinkingLevel":"high"}}
        """
    }

    private func ompAssistant(id: String, start: Double, durationMs: Double, output: Int, stop: String = "toolUse") -> String {
        """
        {"type":"message","id":"\(id)","parentId":"p0","timestamp":"\(isoTime(start + durationMs + 5))","runtime":{"version":"18.14.0"},"message":{"role":"assistant","content":[],"api":"openai-completions","provider":"zai","model":"gemini-4-argon","usage":{"input":4298,"output":\(output),"cacheRead":0,"cacheWrite":0,"totalTokens":\(4298 + output),"reasoningTokens":35},"stopReason":"\(stop)","timestamp":\(Int(start)),"duration":\(durationMs),"completedAt":\(Int(start + durationMs))}}
        """
    }

    private let user = #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-30T11:27:00.000Z","message":{"role":"user","content":"go"}}"#

    func testPiUsesEntryTimeAsEnd() throws {
        try write(session("pi"), [#"{"type":"session","version":3,"id":"s1","timestamp":"2026-10-30T11:24:57.584Z","cwd":"/Users/me/project"}"#,
                                  user, piAssistant(id: "a1", start: now - 10_000, end: now, output: 500, responseId: "resp_1")])
        let found = scan(scanner())
        XCTAssertEqual(found.count, 1)
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.source, .pi)
        XCTAssertEqual(s.model, "openai/gpt-6.1-sol")
        XCTAssertEqual(s.tokens, 500)                      // output already includes reasoning
        XCTAssertEqual(s.duration, 10, accuracy: 0.01)
    }

    func testOMPUsesCompletedAtAndSkipsErrors() throws {
        try write(session("omp"), [
            user,
            ompAssistant(id: "e1", start: now - 30_000, durationMs: 16_000, output: 0, stop: "error"),
            ompAssistant(id: "a1", start: now - 12_000, durationMs: 8_000, output: 400),
        ])
        let found = scan(scanner())
        XCTAssertEqual(found.map(\.source), [.omp])
        XCTAssertEqual(found.first?.model, "zai/gemini-4-argon")
        XCTAssertEqual(found.first?.tps ?? 0, 50, accuracy: 0.01)
    }

    func testOMPSubagentFilesAreRead() throws {
        try write(session("omp", "2026-10-30T11-24-57-584Z_s1/StorageSyncAudit.jsonl"),
                  [ompAssistant(id: "a1", start: now - 5_000, durationMs: 4_000, output: 300)])
        XCTAssertEqual(scan(scanner()).count, 1)
    }

    func testForkedSessionsCountResponsesOnce() throws {
        let a = piAssistant(id: "a1", start: now - 10_000, end: now, output: 500, responseId: "resp_1")
        let b = piAssistant(id: "a2", start: now - 6_000, end: now - 1_000, output: 300)   // no responseId
        try write(session("pi"), [user, a, b])
        try write(session("pi", "2026-10-30T12-00-00-000Z_fork.jsonl"), [user, a, b])
        XCTAssertEqual(scan(scanner()).count, 2)
    }

    func testReadsOnlyAppendedLinesAndSkipsShortReplies() throws {
        let s = scanner()
        try write(session("pi"), [user, piAssistant(id: "a1", start: now - 3_000, end: now - 2_000, output: 14)])
        XCTAssertTrue(scan(s).isEmpty, "14 tokens is below the 200-token minimum")
        try write(session("pi"), [piAssistant(id: "a2", start: now - 4_000, end: now, output: 800)], append: true)
        let found = scan(s)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tps ?? 0, 200, accuracy: 0.01)
        XCTAssertTrue(scan(s).isEmpty)
    }
}
