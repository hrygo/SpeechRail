import Foundation
import Testing
import Synchronization
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct MeetingSpeakerCapacityTests {
    @Test func expectedCountMeansUpperBoundAndUnknownKeepsFour() throws {
        #expect(MeetingExpectedSpeakerCount.uncertain.maximumStableIdentities == nil)
        #expect(MeetingExpectedSpeakerCount.two.maximumStableIdentities == 2)
        #expect(MeetingExpectedSpeakerCount.three.maximumStableIdentities == 3)
        #expect(MeetingExpectedSpeakerCount.four.maximumStableIdentities == 4)
        #expect(MeetingExpectedSpeakerCount.moreThanFour.maximumStableIdentities == 4)
        let request = SpeechRailSessionUpdate(model: "speechrail/qwen3-asr-1.7b",
            diarizationEnabled: true, diarizationBackend: .meetingDynamic, diarizationMaxSpeakers: 2)
        let session = try #require(request.jsonObject["session"] as? [String: Any])
        let ext = try #require(session["speechrail"] as? [String: Any])
        let options = try #require(ext["diarization"] as? [String: Any])
        #expect(options["max_speakers"] as? Int == 2)
        let wrong = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self,
            from: Data(#"{"enabled":true,"backend":"meeting_dynamic","max_speakers":4,"system_cap":4}"#.utf8))
        #expect(!wrong.acceptsRequestedMaximum(2))
        #expect(wrong.acceptsRequestedMaximum(nil))
    }

    @MainActor @Test func dynamicReplayAndLineRetirementPreserveStoredIdentity() async throws {
        let (store, record, _) = try await TranscriptWindowPersistenceTests().fixture()
        let writes = Mutex(0)
        let labeling = SpeakerLabeling(coordinator: SessionCoordinator(store: store), attachAttribution: { lineID, units in
            writes.withLock { $0 += 1 }
            return try await store.attachTranscriptAttribution(lineID: lineID, units: units)
        })
        let capacity = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self,
            from: Data(#"{"enabled":true,"backend":"meeting_dynamic","max_speakers":4,"system_cap":4}"#.utf8))
        labeling.begin(sessionID: record, enabled: true)
        labeling.configureCapacity(capacity, recordID: record, generation: 1,
            serverSessionID: "first", inputEpoch: 0)
        var labels: [String] = []
        for (index, lineID) in ["before-retirement", "after-retirement"].enumerated() {
            _ = try await store.appendLine(LineDraft(sessionID: record, role: .speaker,
                text: "合成分人回归", source: .microphone, status: .final), id: lineID)
            let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit-\(index)", speaker: "S1", textStart: 0, textEnd: 6)]
            let label = try #require(labeling.register(units: units, lineID: lineID, ordinal: index + 1))
            labels.append(label)
            await labeling.apply(units: units)
            await labeling.apply(units: units)
            #expect(writes.withLock { $0 } == index + 1, "A repeated attribution must not write twice")
            labeling.retireLine(lineID)
            #expect(labeling.liveUnitCount == 0)
        }
        #expect(labels[0] == labels[1], "Retiring line indexes must preserve the session speaker scope")
        #expect(try await store.lines(sessionID: record).map(\.speakerLabel) == labels.map(Optional.some))
        labeling.beginNewConnection(sessionID: record)
        labeling.configureCapacity(capacity, recordID: record, generation: 2,
            serverSessionID: "reconnected", inputEpoch: 0)
        let next = labeling.register(units: [.init(segmentUID: "unit-0", speaker: "S1")],
            lineID: "new-connection", ordinal: 3)
        #expect(next == nil, "A new connection has no voice continuity proof and must stay unknown")
        await store.close()
    }

    @Test func historicalScopeOrdinalsRemainStableAcrossSearchFiltering() {
        let first = "d" + String(repeating:"a",count:32) + ":S1"
        let next = "d" + String(repeating:"b",count:32) + ":S1"
        let map = SpeakerLabeling.displayOrdinals(for:[first,next,first])
        #expect(map[first] == 1 && map[next] == 2)
        #expect(SpeakerLabeling.chipText(label:next,displayName:nil,ordinal:map[next]) == "说话人 2")
    }
    @Test func fifthAndSixthLabelsCannotEnterFourIdentityScope() throws {
        var scope = SpeakerScopeBinding(recordID: "record", connectionGeneration: 1,
            serverSessionID: "session", inputEpoch: 0)
        let labels = try (1...4).map { try scope.serverLabel("S\($0)", capacity: 4) }
        for index in [5, 6] {
            #expect(throws: (any Error).self) { try scope.serverLabel("S\(index)", capacity: 4) }
        }
        #expect(try scope.serverLabel("S1", capacity: 4) == labels[0])
        #expect(throws: (any Error).self) { try scope.serverLabel("S5", capacity: 32) }
        #expect(throws: (any Error).self) { try scope.allocateUserLabel(existing: [], capacity: 4) }
    }

    @Test func capacityContractRejectsMoreThanFour() throws {
        for (maximum, cap, valid) in [(4, 4, true), (3, 4, true), (5, 4, false), (8, 32, false)] {
            let json = "{\"enabled\":true,\"backend\":\"meeting_dynamic\",\"max_speakers\":\(maximum),\"system_cap\":\(cap)}"
            let capacity = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self, from: Data(json.utf8))
            #expect(capacity.isValid == valid)
        }
    }

    @MainActor @Test func repeatedHandshakeKeepsScopeAndReconnectRemainsUnknown() async throws {
        let (store, record, _) = try await TranscriptWindowPersistenceTests().fixture()
        let labeling = SpeakerLabeling(coordinator:SessionCoordinator(store:store))
        let capacity = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self,
            from:Data(#"{"enabled":true,"backend":"meeting_dynamic","max_speakers":4,"system_cap":4}"#.utf8))
        labeling.begin(sessionID:record,enabled:true)
        labeling.configureCapacity(capacity,recordID:record,generation:1,serverSessionID:"one",inputEpoch:0)
        let first = labeling.register(units:[.init(segmentUID:"u1",speaker:"S1")],lineID:"line1",ordinal:1)
        labeling.configureCapacity(capacity,recordID:record,generation:1,serverSessionID:"one",inputEpoch:0)
        let repeated = labeling.register(units:[.init(segmentUID:"u2",speaker:"S1")],lineID:"line2",ordinal:2)
        #expect(first == repeated)
        labeling.beginNewConnection(sessionID:record)
        labeling.configureCapacity(capacity,recordID:record,generation:2,serverSessionID:"two",inputEpoch:0)
        let second = labeling.register(units:[.init(segmentUID:"u3",speaker:"S1")],lineID:"line3",ordinal:3)
        #expect(first != nil && second == nil)
        #expect(labeling.summaryText == "说话人 1")
        #expect(labeling.note?.contains("重新连接") == true)
        await store.close()
    }
    @Test func textStatisticsIncludeUnknownGapsAndShortInterjections() {
        let line = TranscriptLine(id: "line", sessionID: "record", ordinal: 1, role: .speaker,
            speakerLabel: "S1", text: "主要发言人。嗯？未知", source: .microphone,
            attributionUnits: [
                .init(id: "known", textStart: 0, textEnd: 5, speakerLabel: "S1"),
                .init(id: "short", textStart: 6, textEnd: 7, speakerLabel: "S2"),
                .init(id: "rejected", textStart: 8, textEnd: 9, speakerLabel: nil)
            ])
        let stats = SpeakerTextStatistics(lines: [line])
        #expect(stats.totalCharacters == 8)
        #expect(stats.charactersBySpeaker == ["S1": 5, "S2": 1])
        #expect(stats.unknownCharacters == 2)
        #expect(stats.share(for: "S2") == 0.125)
        #expect(stats.unknownShare == 0.25)
    }

    @Test func allUnknownAndUnicodeTextKeepTheirDenominator() {
        let unknown = TranscriptLine(id: "unknown", sessionID: "record", ordinal: 1,
            role: .speaker, text: " 中文 A🙂，\n", source: .microphone)
        let empty = TranscriptLine(id: "empty", sessionID: "record", ordinal: 2,
            role: .speaker, speakerLabel: "S1", text: " ！？\n", source: .microphone)
        let partial = TranscriptLine(id: "partial", sessionID: "record", ordinal: 3,
            role: .speaker, speakerLabel: "S1", text: "不计草稿", source: .microphone, status: .partial)
        let stats = SpeakerTextStatistics(lines: [unknown, empty, partial])
        #expect(stats.totalCharacters == 4)
        #expect(stats.unknownCharacters == 4 && stats.unknownShare == 1)
        #expect(stats.charactersBySpeaker.isEmpty)
        #expect(SpeakerTextStatistics(lines: [empty]).unknownShare == 0)
    }

    @Test func invalidAttributionStaysUnknownAndManualWholeLineWins() {
        var line = TranscriptLine(id: "line", sessionID: "record", ordinal: 1,
            role: .speaker, speakerLabel: "S1", text: "甲乙丙", source: .microphone,
            attributionUnits: [.init(id: "bad", textStart: 0, textEnd: 99, speakerLabel: "S1")])
        #expect(SpeakerTextStatistics(lines: [line]).unknownCharacters == 3)
        line.speakerLabelIsManual = true
        #expect(SpeakerTextStatistics(lines: [line]).charactersBySpeaker == ["S1": 3])
    }

    @Test func punctuationOnlyRowDoesNotHideLaterSpeakerFromStatistics() {
        let rows = ["！？", "甲乙"].enumerated().map { index, text in
            TranscriptLine(id: "\(index)", sessionID: "record", ordinal: index + 1,
                role: .speaker, speakerLabel: "S2", text: text, source: .microphone)
        }
        let stats = SpeakerTextStatistics(lines: rows)
        #expect(stats.speakerOrder == ["S2"])
        #expect(stats.charactersBySpeaker == ["S2": 2])
    }

    @MainActor @Test func fourIdentitiesSurviveUnknownInterjectionsAndReconnectWithoutAFifth() async throws {
        let (store, record, _) = try await TranscriptWindowPersistenceTests().fixture()
        let labeling = SpeakerLabeling(coordinator: SessionCoordinator(store: store))
        let capacity = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self,
            from: Data(#"{"enabled":true,"backend":"meeting_dynamic","max_speakers":4,"system_cap":4}"#.utf8))
        labeling.begin(sessionID: record, enabled: true)
        labeling.configureCapacity(capacity, recordID: record, generation: 1, serverSessionID: "one", inputEpoch: 0)
        func save(_ id: String, _ raw: String?, text: String = "甲") async throws -> String? {
            let ordinal = try await store.appendLine(LineDraft(sessionID: record, role: .speaker,
                text: text, source: .microphone), id: id)
            let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: id, speaker: raw,
                textStart: 0, textEnd: text.unicodeScalars.count)]
            let label = labeling.register(units: units, lineID: id, ordinal: ordinal)
            await labeling.apply(units: units)
            return label
        }
        var identities: [String] = []
        for index in 1...4 {
            identities.append(try #require(try await save("known-\(index)", "S\(index)")))
        }
        #expect(try await save("fifth", "S5") == nil)
        #expect(try await save("uncertain-short", nil, text: "嗯") == nil)
        #expect(try await save("returned", "S1") == identities[0])
        let originalRows = try await store.lines(sessionID: record)
        labeling.beginNewConnection(sessionID: record)
        // Even before the new handshake, no label may escape as raw S1.
        #expect(try await save("before-handshake", "S1") == nil)
        labeling.configureCapacity(capacity, recordID: record, generation: 2, serverSessionID: "two", inputEpoch: 0)
        for index in 1...4 { #expect(try await save("reconnect-\(index)", "S\(index)") == nil) }
        let rows = try await store.lines(sessionID: record)
        #expect(Array(rows.prefix(originalRows.count)) == originalRows)
        #expect(labeling.labels == identities)
        let stats = SpeakerTextStatistics(lines: rows)
        #expect(stats.totalCharacters == 12)
        #expect(stats.unknownCharacters == 7)
        #expect(stats.charactersBySpeaker.count == 4)
        await store.close()
    }

}
