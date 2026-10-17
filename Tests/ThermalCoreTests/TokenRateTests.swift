import Foundation
import Testing
@testable import ThermalCore

private func snap(_ reqs: [(String, Int, Double?)], active: Int? = nil) -> ActivitySnapshot {
    ActivitySnapshot(activeRequests: active ?? reqs.count, generating: reqs.map { GeneratingRequest(id: $0.0, tokens: $0.1, elapsed: $0.2) })
}

@Test func firstPollHasNoRate() {
    var t = TokenRateTracker()
    #expect(t.update(snap([("a", 100, 5)]), now: 0) == nil)
}

@Test func rateFromTokenDeltas() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 100, 5)]), now: 0)
    #expect(t.update(snap([("a", 140, 6)]), now: 1) == 40)
    // a new request that started during the interval counts all its tokens
    #expect(t.update(snap([("a", 180, 7), ("b", 10, 0.5)]), now: 2) == 50)
}

@Test func requestStartedBeforeWatchingIsSkipped() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 100, 5)]), now: 0)
    #expect(t.update(snap([("a", 130, 6), ("c", 500, 30)]), now: 1) == 30)
}

@Test func idleAndFailuresGiveNil() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 100, 5)]), now: 0)
    #expect(t.update(snap([], active: 0), now: 1) == nil)
    #expect(t.update(nil, now: 2) == nil)
    // after a failure the next poll is a fresh baseline
    #expect(t.update(snap([("a", 300, 9)]), now: 3) == nil)
    #expect(t.update(snap([("a", 330, 10)]), now: 3) == nil) // time did not advance
}

@Test func decodesActivityAndIgnoresOtherFields() throws {
    let json = """
    {"active_models": {"total_active_requests": 2, "models": [
      {"id": "qwen", "generating": [{"request_id": "a", "generated_tokens": 120, "elapsed_seconds": 3.5}]},
      {"id": "gemma", "generating": [{"request_id": "b", "generated_tokens": 40, "elapsed_seconds": null}, {"generated_tokens": 5}]}
    ]}, "api_key": "should-not-be-read"}
    """
    let s = try ActivitySnapshot.decode(Data(json.utf8))
    #expect(s.activeRequests == 2)
    #expect(s.generating == [GeneratingRequest(id: "a", tokens: 120, elapsed: 3.5), GeneratingRequest(id: "b", tokens: 40, elapsed: nil)])
}

@Test func decodeRejectsWrongShape() {
    #expect(throws: (any Error).self) { try ActivitySnapshot.decode(Data("{\"detail\":\"Not Found\"}".utf8)) }
    #expect(throws: (any Error).self) { try ActivitySnapshot.decode(Data("nope".utf8)) }
}

@Test func envFileParsing() {
    let text = """
    # comment
    export OMLX_KEY="abc#123"
    OTHER=1
    SPACED = 'quoted value'
    """
    #expect(EnvFile.value(named: "OMLX_KEY", in: text) == "abc#123")
    #expect(EnvFile.value(named: "OTHER", in: text) == "1")
    #expect(EnvFile.value(named: "SPACED", in: text) == "quoted value")
    #expect(EnvFile.value(named: "MISSING", in: text) == nil)
}

@Test func envFileKeepsHashAndLastAssignmentWins() {
    let text = "KEY=first\nKEY=second # still part of the value\n"
    #expect(EnvFile.value(named: "KEY", in: text) == "second # still part of the value")
}

@Test func omlxRestartNeverGoesNegative() {
    var t = TokenRateTracker()
    _ = t.update(snap([("a", 500, 20)]), now: 0)
    // oMLX restarted: same id, counter reset to 20, elapsed within the interval
    #expect(t.update(snap([("a", 20, 0.8)]), now: 1) == 0)
    // a new id after restart counts all its tokens when it started within dt
    var u = TokenRateTracker()
    _ = u.update(snap([("a", 500, 20)]), now: 0)
    #expect(u.update(snap([("z", 20, 0.8)]), now: 1) == 20)
}
