import XCTest
import Darwin
@testable import VPNNavigatorCore

final class ConnectionHistoryStoreTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
    func testPrivatePersistenceAndRestartDoesNotCountOfflineTime() async throws {
        let root = try makeRoot(), directory = root.appendingPathComponent("history"), id = UUID(), attempt = UUID(), now = Date()
        let store = ConnectionHistoryStore(directory: directory)
        _ = await store.consume(.begin(profileID: id, attemptID: attempt), date: now, uptime: 1)
        let restarted = ConnectionHistoryStore(directory: directory)
        let state = await restarted.open(now: now.addingTimeInterval(60))
        XCTAssertNil(state.problem); XCTAssertEqual(state.records[0].outcome, .interrupted)
        XCTAssertEqual(state.records[0].endedAt, now)
        for (path, mode) in [(directory, 0o700), (directory.appendingPathComponent("history.json"), 0o600)] {
            let info = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, mode)
        }
    }
    func testMalformedFilePreservedUntilExplicitClearAndPause() async throws {
        let root = try makeRoot(), directory = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("history.json"), bytes = Data("broken archive".utf8)
        try bytes.write(to: file)
        let store = ConnectionHistoryStore(directory: directory)
        let opened = await store.open(); XCTAssertNotNil(opened.problem)
        _ = await store.consume(.begin(profileID: UUID(), attemptID: UUID()), date: Date(), uptime: 1)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let cleared = try await store.clearAndPause(); XCTAssertNil(cleared.problem); XCTAssertFalse(cleared.preferences.enabled); XCTAssertTrue(cleared.records.isEmpty)
        let reopened = await ConnectionHistoryStore(directory: directory).open(); XCTAssertNil(reopened.problem); XCTAssertFalse(reopened.preferences.enabled)
    }
    func testFileAndDirectoryLinksCannotReadOrOverwriteTargets() async throws {
        let root = try makeRoot(), target = root.appendingPathComponent("target.json")
        try Data("keep target".utf8).write(to: target)
        let directory = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("history.json"), withDestinationURL: target)
        let store = ConnectionHistoryStore(directory: directory)
        let state = await store.open(); XCTAssertNotNil(state.problem)
        do { _ = try await store.clearAndPause(); XCTFail() } catch { }
        XCTAssertEqual(try String(contentsOf: target), "keep target")
        let link = root.appendingPathComponent("linked-history")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let linked = await ConnectionHistoryStore(directory: link).open(); XCTAssertNotNil(linked.problem)
    }
    func testCounterCheckpointsAreThrottledAndTransitionsFlushImmediately() async throws {
        let root = try makeRoot(), directory = root.appendingPathComponent("history"), profile = UUID(), attempt = UUID(), now = Date()
        let store = ConnectionHistoryStore(directory: directory)
        func report(_ received: UInt64, state: TunnelState = .connected) -> ConnectionHistoryInput {
            .report(.init(.init(state: state, message: "", activeProfileID: profile, receivedBytes: received, sentBytes: 0,
                attemptID: attempt, networkRecoveryRequired: false, routingMode: .original)))
        }
        _ = await store.consume(report(0), date: now, uptime: 0)
        let file = directory.appendingPathComponent("history.json"), baseline = try Data(contentsOf: file)
        _ = await store.consume(report(1000), date: now.addingTimeInterval(3), uptime: 3)
        XCTAssertEqual(try Data(contentsOf: file), baseline)
        for i in stride(from: 6, through: 30, by: 3) { _ = await store.consume(report(UInt64(i * 1000)), date: now.addingTimeInterval(Double(i)), uptime: Double(i)) }
        XCTAssertNotEqual(try Data(contentsOf: file), baseline)
        _ = await store.consume(report(30_000, state: .disconnected), date: now.addingTimeInterval(31), uptime: 31)
        let archive = try JSONDecoder().decode(ConnectionHistoryArchive.self, from: Data(contentsOf: file))
        XCTAssertEqual(archive.records[0].outcome, .completed); XCTAssertEqual(archive.records[0].receivedBytes, 30_000)
    }
    func testPreferencesPersistAndClearDoesNotResumeOnNextPoll() async throws {
        let root = try makeRoot(), directory = root.appendingPathComponent("history"), store = ConnectionHistoryStore(directory: directory)
        _ = try await store.configure(.init(enabled: true, retentionDays: 90))
        _ = await store.consume(.begin(profileID: UUID(), attemptID: UUID()), date: Date(), uptime: 1)
        _ = try await store.clearAndPause()
        _ = await store.consume(.begin(profileID: UUID(), attemptID: UUID()), date: Date(), uptime: 2)
        let result = await ConnectionHistoryStore(directory: directory).open()
        XCTAssertFalse(result.preferences.enabled); XCTAssertEqual(result.preferences.retentionDays, 90); XCTAssertTrue(result.records.isEmpty)
    }
    func testOversizeAndUnknownSchemaAreNotSilentlyReplaced() async throws {
        let root = try makeRoot(), directory = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("history.json")
        for data in [Data(repeating: 0x20, count: 2_000_001), Data("{\"schema\":99,\"preferences\":{\"enabled\":true,\"retentionDays\":7},\"records\":[]}".utf8)] {
            try data.write(to: file)
            let opened = await ConnectionHistoryStore(directory: directory).open()
            XCTAssertNotNil(opened.problem); XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
}
