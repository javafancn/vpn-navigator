import Foundation
import XCTest
@testable import VPNNavigatorCore

final class ProfileOpenQueueTests: XCTestCase {
    func testAdmissionDoesNotRequireFilesAndPreservesOrder() {
        let first = URL(fileURLWithPath: "/absent/工作.ovpn")
        let second = URL(fileURLWithPath: "/absent/second.OVPN")
        var queue = ProfileOpenQueue(); queue.append([first, second])
        XCTAssertEqual(queue.urls, [first, second])
        XCTAssertEqual(queue.filenames, ["工作.ovpn", "second.OVPN"])
    }
    func testRejectsRemoteAndAmbiguousURLs() {
        var queue = ProfileOpenQueue()
        queue.append([URL(string: "https://example.com/a.ovpn")!,
                      URL(string: "file://remote.invalid/a.ovpn")!,
                      URL(string: "file:///tmp/a.ovpn?token=secret")!,
                      URL(string: "file:///tmp/a.ovpn#fragment")!,
                      URL(string: "file://user:password@localhost/a.ovpn")!,
                      URL(fileURLWithPath: "/tmp/folder.ovpn", isDirectory: true),
                      URL(fileURLWithPath: "/tmp/a.txt"),
                      URL(string: "file:///tmp/zero%00.ovpn")!])
        XCTAssertTrue(queue.urls.isEmpty)
        XCTAssertEqual(queue.unsupportedCount, 8)
        XCTAssertFalse(queue.isEmpty)
    }
    func testDeduplicatesLexicalPathsAcrossRequests() {
        var queue = ProfileOpenQueue()
        let original = URL(fileURLWithPath: "/tmp/sub/../a.ovpn")
        queue.append([original, URL(fileURLWithPath: "/tmp/a.ovpn")])
        var another = ProfileOpenQueue(); another.append([URL(fileURLWithPath: "/tmp/a.ovpn")])
        queue.merge(another)
        XCTAssertEqual(queue.urls, [original])
        XCTAssertEqual(queue.duplicateCount, 2)
    }
    func testPerRequestAndPendingCapacityAreBounded() {
        var queue = ProfileOpenQueue()
        queue.append((0..<110).map { URL(fileURLWithPath: "/absent/\($0).ovpn") })
        XCTAssertEqual(queue.urls.count, 100)
        XCTAssertEqual(queue.overflowCount, 10)
        queue.append([URL(fileURLWithPath: "/absent/next.ovpn")])
        XCTAssertEqual(queue.urls.count, 100)
        XCTAssertEqual(queue.overflowCount, 11)
    }
    func testMergeRetainsRejectionCategoriesAndClearDropsAllURLs() {
        var queue = ProfileOpenQueue()
        var incoming = ProfileOpenQueue()
        incoming.append([URL(fileURLWithPath: "/a.ovpn"), URL(fileURLWithPath: "/readme.txt")])
        incoming.recordUnresolved(2, overflow: 3)
        queue.merge(incoming)
        XCTAssertEqual(queue.unsupportedCount, 1)
        XCTAssertEqual(queue.unreadableCount, 2)
        XCTAssertEqual(queue.overflowCount, 3)
        queue.clear()
        XCTAssertEqual(queue, ProfileOpenQueue())
    }
    func testReviewNamesHaveNoParentPathOrControlCharacters() {
        var queue = ProfileOpenQueue()
        queue.append([URL(fileURLWithPath: "/private/customer/first\nsecond.ovpn")])
        XCTAssertEqual(queue.filenames, ["firstsecond.ovpn"])
    }
    func testProviderFailureCountsAreSaturating() {
        var queue = ProfileOpenQueue()
        queue.recordUnresolved(Int.max, overflow: Int.max)
        queue.recordUnresolved(10, overflow: 10)
        XCTAssertEqual(queue.unreadableCount, 1_000_000)
        XCTAssertEqual(queue.overflowCount, 1_000_000)
    }
}
