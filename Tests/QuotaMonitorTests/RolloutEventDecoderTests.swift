import Foundation
import Testing
@testable import QuotaMonitor

@Suite("RolloutEvent decoder")
struct RolloutEventDecoderTests {

    @Test("service tier rollout values normalize to preferences")
    func serviceTierPreferenceNormalization() {
        #expect(CodexServiceTierPreference(rolloutValue: "priority") == .priority)
        #expect(CodexServiceTierPreference(rolloutValue: " FAST ") == .priority)
        #expect(CodexServiceTierPreference(rolloutValue: "default") == .standard)
        #expect(CodexServiceTierPreference.standard.rawValue == "default")
        #expect(CodexServiceTierPreference(rolloutValue: nil) == nil)
        #expect(CodexServiceTierPreference(rolloutValue: "flex") == nil)
    }

    @Test("nested thread settings decode the service tier")
    func nestedThreadSettingsApplied() throws {
        let line = Data(#"""
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .threadSettingsApplied(let payload, let timestamp) = event else {
            Issue.record("expected .threadSettingsApplied, got \(event)")
            return
        }
        #expect(payload.resolvedServiceTier == "priority")
        #expect(CodexServiceTierPreference(rolloutValue: payload.resolvedServiceTier) == .priority)
        #expect(timestamp == nil)
    }

    @Test("top-level compatible thread settings decode the service tier")
    func topLevelThreadSettingsApplied() throws {
        let line = Data(#"""
        {"type":"event_msg","payload":{"type":"thread_settings_applied","service_tier":"default"}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .threadSettingsApplied(let payload, _) = event else {
            Issue.record("expected .threadSettingsApplied, got \(event)")
            return
        }
        #expect(payload.resolvedServiceTier == "default")
        #expect(CodexServiceTierPreference(rolloutValue: payload.resolvedServiceTier) == .standard)
    }

    @Test("thread settings without a service tier remain typed")
    func threadSettingsAppliedWithoutTier() throws {
        let line = Data(#"""
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{}}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .threadSettingsApplied(let payload, _) = event else {
            Issue.record("expected .threadSettingsApplied, got \(event)")
            return
        }
        #expect(payload.resolvedServiceTier == nil)
    }

    @Test("task started decodes its turn ID")
    func taskStarted() throws {
        let line = Data(#"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .taskStarted(let payload, _) = event else {
            Issue.record("expected .taskStarted, got \(event)")
            return
        }
        #expect(payload.turnId == "turn-a")
    }

    @Test("task complete preserves a null turn ID")
    func taskCompleteWithNullTurnId() throws {
        let line = Data(#"""
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":null}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .taskComplete(let payload, _) = event else {
            Issue.record("expected .taskComplete, got \(event)")
            return
        }
        #expect(payload.turnId == nil)
    }

    @Test("turn context decodes its turn ID")
    func turnContextTurnId() throws {
        let line = Data(#"""
        {"type":"turn_context","payload":{"model":"gpt-5","turn_id":"turn-context"}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .turnContext(let payload, _) = event else {
            Issue.record("expected .turnContext, got \(event)")
            return
        }
        #expect(payload.turnId == "turn-context")
    }

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

    @Test("unknown event payloads do not decode beyond the inner type")
    func unknownEventPayloadIsSkipped() throws {
        let line = Data(#"""
        {"timestamp":"2026-05-20T00:00:01.000Z","type":"event_msg","payload":{"type":"unknown_event","bad_number":1e999}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .other(let type, let timestamp) = event else {
            Issue.record("expected .other, got \(event)")
            return
        }
        #expect(type == "event_msg")
        #expect(timestamp == "2026-05-20T00:00:01.000Z")
    }
}
