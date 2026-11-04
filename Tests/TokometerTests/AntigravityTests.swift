import XCTest
@testable import Tokometer

final class AntigravityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func testFindsEveryVariantAndT3CodeDirs() throws {
        for path in ["gemini/antigravity/conversations", "gemini/antigravity-cli/conversations",
                     "gemini/antigravity-ide/conversations", "gemini/antigravity-insiders/conversations",
                     "gemini/antigravity-nobody/brain",            // no conversations dir
                     "gemini/tmp/conversations",                   // not Antigravity
                     "t3/abc123/antigravity-acp/conversations", "t3/abc123/antigravity-cli/skills"] {
            try mkdir(path)
        }
        let s = Tokometer.Scanner()
        s.antigravityRoots = (root.appendingPathComponent("gemini"), root.appendingPathComponent("t3"))
        let found = s.antigravityConversationDirs().map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        XCTAssertEqual(Set(found), [
            "gemini/antigravity/conversations", "gemini/antigravity-cli/conversations",
            "gemini/antigravity-ide/conversations", "gemini/antigravity-insiders/conversations",
            "t3/abc123/antigravity-acp/conversations",
        ])
    }

    func testMissingRootsAreFine() {
        let s = Tokometer.Scanner()
        s.antigravityRoots = (root.appendingPathComponent("nope"), root.appendingPathComponent("nope2"))
        XCTAssertEqual(s.antigravityConversationDirs(), [])
    }
}

extension AntigravityTests {
    func testNewDirsExcludeOriginalOnes() throws {
        for path in ["gemini/antigravity/conversations", "gemini/antigravity-ide/conversations",
                     "gemini/antigravity-insiders/conversations", "t3/abc/antigravity-acp/conversations"] {
            try mkdir(path)
        }
        let s = Tokometer.Scanner()
        s.antigravityRoots = (root.appendingPathComponent("gemini"), root.appendingPathComponent("t3"))
        let found = s.newAntigravityDirs().map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        XCTAssertEqual(Set(found), ["gemini/antigravity-insiders/conversations", "t3/abc/antigravity-acp/conversations"])
    }
}
