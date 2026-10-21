import XCTest
import Darwin
@testable import VPNNavigatorCore

final class ProfileTransferTests: XCTestCase {
    private let sample = "client\ndev tun\nremote vpn.example 1194\n<ca>\nFAKE-CA\n</ca>\n<key>\nFAKE-PRIVATE-KEY\n</key>\nauth-user-pass\n"
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    func testPortableRoundTripSurvivesRemovalOfExternalMaterial() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try "FAKE-CA".write(to: input.appendingPathComponent("ca.pem"), atomically: true, encoding: .utf8)
        try "FAKE-PRIVATE-KEY".write(to: input.appendingPathComponent("key.pem"), atomically: true, encoding: .utf8)
        let source = input.appendingPathComponent("client.ovpn")
        try "client\ndev tun\nremote vpn.example 1194\nca ca.pem\nkey key.pem\nauth-user-pass account.txt\n".write(to: source, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root.appendingPathComponent("store"))
        let profile = try await store.importProfile(from: source)
        let runtime = try await store.runtimeConfig(for: profile)
        try FileManager.default.removeItem(at: input)
        let portable = try ProfileExport.render(runtime: runtime, kind: .portable, mode: .chinaDirect, rules: nil)
        let destination = root.appendingPathComponent("portable.ovpn")
        try ProfileFileIO.write(portable, to: destination)
        let other = ProfileStore(root: root.appendingPathComponent("other"))
        let imported = try await other.importProfile(from: destination)
        let roundTrip = try await other.runtimeConfig(for: imported)
        XCTAssertNoThrow(try ProfileSafety.validate(roundTrip))
        XCTAssertTrue(roundTrip.contains("FAKE-PRIVATE-KEY"))
        XCTAssertFalse(roundTrip.contains("ca.pem"))
        XCTAssertFalse(roundTrip.contains("account.txt"))
        XCTAssertFalse(roundTrip.contains("VPNNAVIGATOR GENERATED ROUTES"))
        XCTAssertFalse(roundTrip.contains("redirect-gateway"))
    }
    func testPreviewIsSeparateAndPortablePreservesOriginalRoutes() throws {
        let source = sample + "route 10.0.0.0 255.0.0.0 vpn_gateway\n"
        let portable = try ProfileExport.render(runtime: source, kind: .portable, mode: .fullVPN, rules: nil)
        let preview = try ProfileExport.render(runtime: source, kind: .routePreview, mode: .fullVPN, rules: nil)
        XCTAssertEqual(String(decoding: portable, as: UTF8.self), source)
        XCTAssertTrue(String(decoding: preview, as: UTF8.self).contains("# VPNNAVIGATOR GENERATED ROUTES"))
        XCTAssertTrue(String(decoding: preview, as: UTF8.self).contains("redirect-gateway def1"))
        XCTAssertThrowsError(try ProfileExport.render(runtime: "client\nremote host\nca missing.pem", kind: .portable, mode: .original, rules: nil))
    }
    func testExportNamesStayBasenamesAndWithinFilesystemLimits() {
        for value in ["../bad/path:\\file\n", "...", String(repeating: "配置", count: 200)] {
            let name = ProfileExport.filename(name: value, kind: .portable)
            XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains("\\")); XCTAssertFalse(name.contains("\n"))
            XCTAssertTrue(name.utf8.count < 255); XCTAssertTrue(name.hasSuffix(".ovpn"))
        }
    }
    func testPrivatePublicationReplacesOnlyTheSelectedHardLink() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.ovpn"), linked = root.appendingPathComponent("linked.ovpn")
        try Data("OLD".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: linked)
        try ProfileFileIO.write(Data(sample.utf8), to: first)
        XCTAssertEqual(try String(contentsOf: linked), "OLD")
        XCTAssertEqual(try String(contentsOf: first), sample)
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".vpnnav-export-") })
    }
    func testSymlinkAndDirectoryExportsPreserveExistingContent() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link.ovpn")
        try Data("PRESERVED".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ProfileFileIO.write(Data(sample.utf8), to: link))
        XCTAssertThrowsError(try ProfileFileIO.write(Data(sample.utf8), to: root))
        XCTAssertEqual(try String(contentsOf: target), "PRESERVED")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
    func testBoundedReadsRejectOversizeAndPipesWithoutWaiting() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.ovpn"), pipe = root.appendingPathComponent("pipe.ovpn")
        try Data(repeating: 0x61, count: 101).write(to: big)
        XCTAssertThrowsError(try ProfileFileIO.read(big, maximumBytes: 100))
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try ProfileFileIO.read(pipe))
    }
    func testBatchKeepsAllResultsAndContinuesAfterFailure() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.ovpn"), bad = root.appendingPathComponent("bad.ovpn"), b = root.appendingPathComponent("b.ovpn")
        try sample.write(to: a, atomically: true, encoding: .utf8)
        try "invalid".write(to: bad, atomically: true, encoding: .utf8)
        try sample.write(to: b, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: root.appendingPathComponent("store"))
        let results = try await ProfileBatchImporter(store: store).run([a, bad, b], cancellation: .init())
        XCTAssertEqual(results.map(\.filename), ["a.ovpn", "bad.ovpn", "b.ovpn"])
        XCTAssertEqual(results[1].status, .failed(.invalidFile))
        guard case .imported = results[0].status, case .imported = results[2].status else { return XCTFail("Valid files lost") }
        let profiles = try await store.list()
        XCTAssertEqual(profiles.count, 2)
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("store"), includingPropertiesForKeys: nil) {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testCancellationBeforeStartDoesNotReadAnyFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let cancellation = ProfileImportCancellation(); cancellation.cancel()
        let store = ProfileStore(root: root.appendingPathComponent("store"))
        let results = try await ProfileBatchImporter(store: store).run([root.appendingPathComponent("missing.ovpn")], cancellation: cancellation)
        XCTAssertEqual(results.first?.status, .cancelled)
        let profiles = try await store.list(); XCTAssertTrue(profiles.isEmpty)
    }
    func testCancelBetweenFilesKeepsCompletedImport() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.ovpn"), b = root.appendingPathComponent("missing.ovpn")
        try sample.write(to: a, atomically: true, encoding: .utf8)
        let cancellation = ProfileImportCancellation(), store = ProfileStore(root: root.appendingPathComponent("store"))
        let results = try await ProfileBatchImporter(store: store).run([a, b], cancellation: cancellation) { results in
            if case .imported = results[0].status { cancellation.cancel() }
        }
        guard case .imported = results[0].status else { return XCTFail("Completed file lost") }
        XCTAssertEqual(results[1].status, .cancelled)
        let profiles = try await store.list(); XCTAssertEqual(profiles.count, 1)
    }
    func testBatchLimitAndIndexFailureLeaveNoPartialFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ovpn"), storeRoot = root.appendingPathComponent("store")
        try sample.write(to: source, atomically: true, encoding: .utf8)
        let store = ProfileStore(root: storeRoot)
        do { _ = try await ProfileBatchImporter(store: store).run(Array(repeating: source, count: 101), cancellation: .init()); XCTFail("Limit ignored") } catch {}
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        let absent = root.appendingPathComponent("absent-index")
        try FileManager.default.createSymbolicLink(at: storeRoot.appendingPathComponent("profiles.json"), withDestinationURL: absent)
        do { _ = try await store.importProfile(from: source); XCTFail("Unsafe index accepted") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storeRoot.path), ["profiles.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }
}
