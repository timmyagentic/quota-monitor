import Foundation
import Testing
@testable import QuotaMonitor

@Suite("RolloutEvent decoder")
struct RolloutEventDecoderTests {

    @Test("one decoder can be reused across rollout lines")
    func decoderCanBeReusedAcrossLines() throws {
        let decoder = JSONDecoder()
        let lines = [
            Data(#"{"type":"turn_context","payload":{"model":"gpt-5"}}"#.utf8),
            Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#.utf8),
            Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#.utf8),
        ]

        let events = lines.compactMap {
            RolloutEvent.decode(line: $0, decoder: decoder)
        }

        #expect(events.count == 3)
        guard case .turnContext = events[0] else {
            Issue.record("expected turn context")
            return
        }
        guard case .taskStarted = events[1] else {
            Issue.record("expected task started")
            return
        }
        guard case .taskComplete = events[2] else {
            Issue.record("expected task complete")
            return
        }
    }

    @Test("production rollout loops pass one local decoder")
    func productionLoopsReuseLocalDecoder() throws {
        let parser = try Self.source(named: "QuotaMonitor/Core/Importer/RolloutParser.swift")
        let importer = try Self.source(named: "QuotaMonitor/Core/Importer/ImportEngine.swift")

        #expect(parser.contains("let eventDecoder = JSONDecoder()"))
        #expect(parser.contains("decoder: eventDecoder"))
        #expect(importer.components(separatedBy: "let eventDecoder = JSONDecoder()").count - 1 == 2)
        #expect(importer.components(separatedBy: "decoder: eventDecoder").count - 1 == 2)
    }

    @Test("service tier rollout values normalize to preferences")
    func serviceTierPreferenceNormalization() {
        #expect(CodexServiceTierPreference(rolloutValue: "priority") == .priority)
        #expect(CodexServiceTierPreference(rolloutValue: " FAST ") == .priority)
        #expect(CodexServiceTierPreference(rolloutValue: "default") == .standard)
        #expect(CodexServiceTierPreference.standard.rawValue == "default")
        #expect(CodexServiceTierPreference(rolloutValue: nil) == nil)
        #expect(CodexServiceTierPreference(rolloutValue: "flex")?.rawValue == "flex")
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
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":1784041495}}
        """#.utf8)

        let event = try #require(RolloutEvent.decode(line: line))
        guard case .taskStarted(let payload, _) = event else {
            Issue.record("expected .taskStarted, got \(event)")
            return
        }
        #expect(payload.turnId == "turn-a")
        #expect(payload.startedAt == 1_784_041_495)
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

    private static func source(named relativePath: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let candidate = url.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
