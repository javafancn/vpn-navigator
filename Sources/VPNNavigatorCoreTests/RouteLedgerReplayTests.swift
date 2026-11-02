import XCTest
@testable import VPNNavigatorCore

final class RouteLedgerReplayTests: XCTestCase {
    func testCheckpointReplaysLaterMutationsInOrder() throws {
        let first = RouteTarget(try IPv4CIDR("11.0.1.0/24"), .viaGateway("192.168.1.1"))
        let second = RouteTarget(try IPv4CIDR("11.0.2.0/24"), .viaGateway("192.168.1.1"))
        let v6 = IPv6RouteTarget(try IPv6CIDR("240e::/32"), .viaGateway("2001:db8::1"))
        var bytes = try JSONEncoder().encode(RouteLedgerCheckpoint(installed: [first], installed6: [v6])); bytes.append(10)
        let remove = RouteMutation(action: .remove, route: first), add = RouteMutation(action: .add, route: second)
        bytes.append(try encoded([.init(phase: .begun, mutation: remove), .init(phase: .committed, mutation: remove),
                                  .init(phase: .begun, mutation: add), .init(phase: .committed, mutation: add)]))
        let replay = RouteLedgerReplay(data: bytes)
        XCTAssertTrue(replay.permitsAutomaticRecovery)
        XCTAssertEqual(replay.installed, [second]); XCTAssertEqual(replay.installed6, [v6])
    }
    func testCheckpointCannotEraseUncertainMutationsOrRepeatInStream() throws {
        let route = RouteTarget(try IPv4CIDR("11.0.1.0/24"), .viaGateway("192.168.1.1"))
        var checkpoint = try JSONEncoder().encode(RouteLedgerCheckpoint(installed: [], installed6: [])); checkpoint.append(10)
        var bytes = try encoded([.init(phase: .begun, mutation: .init(action: .add, route: route))])
        bytes.append(checkpoint)
        let replay = RouteLedgerReplay(data: bytes)
        XCTAssertFalse(replay.permitsAutomaticRecovery); XCTAssertTrue(replay.malformed); XCTAssertEqual(replay.uncertain.count, 1)
        XCTAssertFalse(RouteLedgerReplay(data: checkpoint + checkpoint).permitsAutomaticRecovery)
        let duplicate = try JSONEncoder().encode(RouteLedgerCheckpoint(installed: [route, route], installed6: []))
        XCTAssertFalse(RouteLedgerReplay(data: duplicate).permitsAutomaticRecovery)
    }
    private func encoded(_ values: [RouteLedgerEvent]) throws -> Data {
        var bytes = Data()
        for value in values {
            bytes.append(try JSONEncoder().encode(value))
            bytes.append(10)
        }
        return bytes
    }
    func testCommittedAddAndRemoveReplay() throws {
        let route = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        let add = RouteMutation(action: .add, route: route)
        let remove = RouteMutation(action: .remove, route: route)
        let events: [RouteLedgerEvent] = [
            .init(phase: .begun, mutation: add),
            .init(phase: .committed, mutation: add),
            .init(phase: .begun, mutation: remove),
            .init(phase: .committed, mutation: remove)
        ]
        let mid = RouteLedgerReplay(data: try encoded(Array(events.prefix(2))))
        XCTAssertTrue(mid.permitsAutomaticRecovery)
        XCTAssertEqual(mid.installed, [route])
        let final = RouteLedgerReplay(data: try encoded(events))
        XCTAssertTrue(final.permitsAutomaticRecovery)
        XCTAssertTrue(final.installed.isEmpty)
    }
    func testCrashBetweenRouteAddAndCommitMustNotAutoCleanup() throws {
        let route = RouteTarget(try IPv4CIDR("223.5.5.0/24"), .viaGateway("192.168.1.1"))
        let mutation = RouteMutation(action: .add, route: route)
        let replay = RouteLedgerReplay(data: try encoded([.init(phase: .begun, mutation: mutation)]))
        XCTAssertFalse(replay.permitsAutomaticRecovery)
        XCTAssertEqual(replay.uncertain, [mutation])
    }
    func testTornJournalAndForgedCompletionFailClosed() throws {
        let route = RouteTarget(try IPv4CIDR("1.0.1.0/24"), .viaGateway("192.168.1.1"))
        let add = RouteMutation(action: .add, route: route)
        var torn = try encoded([.init(phase: .begun, mutation: add)])
        torn.append(Data("{\"phase\":".utf8))
        XCTAssertFalse(RouteLedgerReplay(data: torn).permitsAutomaticRecovery)
        let forged = RouteLedgerReplay(data: try encoded([.init(phase: .committed, mutation: add)]))
        XCTAssertFalse(forged.permitsAutomaticRecovery)
    }
    func testLegacyJournalsStillReadable() throws {
        let route = RouteTarget(try IPv4CIDR("1.0.1.0/24"), .viaGateway("192.168.1.1"))
        let original = try JSONEncoder().encode([route])
        XCTAssertEqual(RouteLedgerReplay(data: original).installed, [route])
        XCTAssertTrue(RouteLedgerReplay(data: original).permitsAutomaticRecovery)
    }
}
