import Foundation
import SpeechRailControlKit

/// Minimal seam for the Realtime transport used by the teleprompter.
///
/// Production uses the existing `RealtimeASRClient`; tests can inject a fake
/// actor to prove that late connects and stop failures cannot leave a hidden
/// capture owner behind.
public protocol TeleprompterRealtimeClientProtocol: Sendable {
    func connect() async throws
    func events() async -> AsyncStream<RealtimeEventEnvelope<RealtimeASRClient.Event>>
    func append(_ pcm: Data) async throws
    func drainAndClear(timeout: Duration) async throws
    func close() async
}

extension RealtimeASRClient: TeleprompterRealtimeClientProtocol {}
