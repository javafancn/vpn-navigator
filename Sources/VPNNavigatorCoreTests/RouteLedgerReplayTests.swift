import XCTest
@testable import VPNNavigatorCore

final class RouteLedgerReplayTests: XCTestCase {
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
