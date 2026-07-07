import Foundation
import Testing
@testable import QuotaMonitor

@Suite("RolloutEvent decoder")
struct RolloutEventDecoderTests {

    @Test("irrelevant top-level events do not decode payload")
    func irrelevantTopLevelPayloadIsSkipped() throws {
        let line = Data(#"""
        {"timestamp":"2026-05-20T00:00:00.000Z","type":"response_item","payload":{"text":"ignored","bad_number":1e999}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .other(let type, let timestamp) = event else {
            Issue.record("expected .other, got \(event)")
            return
        }
        #expect(type == "response_item")
        #expect(timestamp == "2026-05-20T00:00:00.000Z")
    }

    @Test("non-token event_msg payloads do not decode beyond the inner type")
    func nonTokenEventPayloadIsSkipped() throws {
        let line = Data(#"""
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"event_msg","payload":{"type":"task_complete","bad_number":1e999}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .other(let type, let timestamp) = event else {
            Issue.record("expected .other, got \(event)")
            return
        }
        #expect(type == "event_msg")
        #expect(timestamp == "2026-05-20T00:00:01.000Z")
    }

    @Test("event_msg/task_started decodes into .taskStarted carrying its turn_id")
    func taskStartedDecodesTurnId() throws {
        let line = Data(#"""
        {"timestamp":"2026-07-07T13:01:27.134Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f3cab-4c83-7d32-9af3-9834522c00df","started_at":1783429287}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .taskStarted(let turnId, let timestamp) = event else {
            Issue.record("expected .taskStarted, got \(event)")
            return
        }
        #expect(turnId == "019f3cab-4c83-7d32-9af3-9834522c00df")
        #expect(timestamp == "2026-07-07T13:01:27.134Z")
    }
}
