import Foundation
import Testing
import Synchronization
import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct MeetingSpeakerCapacityTests {
    @MainActor @Test func dynamicReplayAndLineRetirementPreserveStoredIdentity() async throws {
        let (store, record, _) = try await TranscriptWindowPersistenceTests().fixture()
        let writes = Mutex(0)
        let labeling = SpeakerLabeling(coordinator: SessionCoordinator(store: store), attachAttribution: { lineID, units in
            writes.withLock { $0 += 1 }
            return try await store.attachTranscriptAttribution(lineID: lineID, units: units)
        })
        let capacity = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self,
            from: Data(#"{"enabled":true,"backend":"meeting_dynamic","max_speakers":8,"system_cap":32}"#.utf8))
        labeling.begin(sessionID: record, enabled: true)
        labeling.configureCapacity(capacity, recordID: record, generation: 1,
            serverSessionID: "first", inputEpoch: 0)
        var labels: [String] = []
        for (index, lineID) in ["before-retirement", "after-retirement"].enumerated() {
            _ = try await store.appendLine(LineDraft(sessionID: record, role: .speaker,
                text: "合成分人回归", source: .microphone, status: .final), id: lineID)
            let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit-\(index)", speaker: "S5", textStart: 0, textEnd: 6)]
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
        let next = labeling.register(units: [.init(segmentUID: "unit-0", speaker: "S5")],
            lineID: "new-connection", ordinal: 3)
        #expect(next != labels[0], "Reused server labels on a new connection must not inherit identity")
        await store.close()
    }

    @Test func historicalScopeOrdinalsRemainStableAcrossSearchFiltering() {
        let first = "d" + String(repeating:"a",count:32) + ":S1"
        let next = "d" + String(repeating:"b",count:32) + ":S1"
        let map = SpeakerLabeling.displayOrdinals(for:[first,next,first])
        #expect(map[first] == 1 && map[next] == 2)
        #expect(SpeakerLabeling.chipText(label:next,displayName:nil,ordinal:map[next]) == "说话人 2")
    }
    @Test func fifthThroughThirtySecondLabelsAreOpaqueAndStable() throws {
        var scope = SpeakerScopeBinding(recordID: "record", connectionGeneration: 1,
            serverSessionID: "session", inputEpoch: 0)
        for index in [5,26,27,32] {
            let label = try scope.serverLabel("S\(index)", capacity: 32)
            #expect(label.hasSuffix(":S\(index)"))
            #expect(label == (try scope.serverLabel("S\(index)", capacity:32)))
        }
        let user = try scope.allocateUserLabel(existing:[],capacity:32)
        #expect(user.hasSuffix(":U1"))
        #expect(try scope.serverLabel("S5",capacity:32) != user)
        #expect(throws:(any Error).self) { try scope.serverLabel("S33",capacity:32) }
        #expect(throws:(any Error).self) { try scope.serverLabel("S01",capacity:32) }
    }
    @Test func reconnectCreatesIndependentScopeAndSplitAtCapacityRefuses() throws {
        var first = SpeakerScopeBinding(recordID:"record",connectionGeneration:1,serverSessionID:"one",inputEpoch:0)
        var second = SpeakerScopeBinding(recordID:"record",connectionGeneration:2,serverSessionID:"two",inputEpoch:0)
        #expect(try first.serverLabel("S1",capacity:32) != second.serverLabel("S1",capacity:32))
        let full = try Set((1...32).map { try first.serverLabel("S\($0)",capacity:32) })
        #expect(throws:(any Error).self) { try first.allocateUserLabel(existing:full,capacity:32) }
    }
    @Test func manualIdentityAndLateServerIdentityShareTheScopeCapacity() throws {
        var scope = SpeakerScopeBinding(recordID:"record",connectionGeneration:1,
            serverSessionID:"session",inputEpoch:0)
        let existing = try Set((1...7).map { try scope.serverLabel("S\($0)",capacity:8) })
        let user = try scope.allocateUserLabel(existing:existing,capacity:8)
        #expect(user.hasSuffix(":U1"))
        #expect(throws:(any Error).self) { try scope.serverLabel("S8",capacity:8) }
        #expect(try scope.serverLabel("S1",capacity:8) == existing.first(where:{$0.hasSuffix(":S1")}))
        #expect(throws:(any Error).self) { try scope.allocateUserLabel(existing:[],capacity:8) }
    }

    @MainActor @Test func repeatedHandshakeKeepsScopeAndReconnectGetsANewDisplayOrdinal() async throws {
        let (store, record, _) = try await TranscriptWindowPersistenceTests().fixture()
        let labeling = SpeakerLabeling(coordinator:SessionCoordinator(store:store))
        let capacity = try JSONDecoder().decode(SpeechRailDiarizationCapacity.self,
            from:Data(#"{"enabled":true,"backend":"meeting_dynamic","max_speakers":8,"system_cap":32}"#.utf8))
        labeling.begin(sessionID:record,enabled:true)
        labeling.configureCapacity(capacity,recordID:record,generation:1,serverSessionID:"one",inputEpoch:0)
        let first = labeling.register(units:[.init(segmentUID:"u1",speaker:"S1")],lineID:"line1",ordinal:1)
        labeling.configureCapacity(capacity,recordID:record,generation:1,serverSessionID:"one",inputEpoch:0)
        let repeated = labeling.register(units:[.init(segmentUID:"u2",speaker:"S1")],lineID:"line2",ordinal:2)
        #expect(first == repeated)
        labeling.beginNewConnection(sessionID:record)
        labeling.configureCapacity(capacity,recordID:record,generation:2,serverSessionID:"two",inputEpoch:0)
        let second = labeling.register(units:[.init(segmentUID:"u3",speaker:"S1")],lineID:"line3",ordinal:3)
        #expect(first != second)
        #expect(labeling.summaryText == "说话人 1、说话人 2")
        await store.close()
    }
}
