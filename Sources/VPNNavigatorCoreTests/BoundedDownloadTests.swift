import XCTest
@testable import VPNNavigatorCore

/// Synthetic HTTPS responses exercise real URLSession delegate delivery; no
/// external server, certificate exception or system networking changes.
final class DownloadFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "download.vpnnav.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let headers = path == "/declared" ? ["Content-Length": "1000000"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: path == "/error" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if path == "/stall" { return }
        if path != "/empty" {
            for _ in 0..<(path == "/chunks" ? 20 : 1) { client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 64)) }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BoundedDownloadTests: XCTestCase {
    private var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]; return configuration
    }
    private func url(_ path: String) -> URL { URL(string: "https://download.vpnnav.test/" + path)! }
    func testUnknownLengthChunkedOversizeAndDeclaredOversizeRejected() async throws {
        for path in ["chunks", "declared"] {
            do { _ = try await BoundedDownload.data(from: url(path), maximumBytes: 128, allowedHosts: ["download.vpnnav.test"], configuration: configuration); XCTFail("Unbounded response accepted") }
            catch ProfileFileIO.Failure.tooLarge {}
        }
    }
    func testExactBoundaryAndDiskDownload() async throws {
        let data = try await BoundedDownload.data(from: url("ok"), maximumBytes: 64, allowedHosts: ["download.vpnnav.test"], configuration: configuration)
        XCTAssertEqual(data.count, 64)
        let file = try await BoundedDownload.file(from: url("ok"), maximumBytes: 64, allowedHosts: ["download.vpnnav.test"], configuration: configuration)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testAbsoluteDeadlineAndCancellationRemoveTemporaryFiles() async throws {
        func pendingFiles() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("vpnnav-download-") }) }
        let before = try pendingFiles()
        do { _ = try await BoundedDownload.file(from: url("stall"), maximumBytes: 128, allowedHosts: ["download.vpnnav.test"], timeout: 0.1, configuration: configuration); XCTFail() }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let task = Task { try await BoundedDownload.file(from: url("stall"), maximumBytes: 128, allowedHosts: ["download.vpnnav.test"], configuration: configuration) }
        try await Task.sleep(nanoseconds: 30_000_000); task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        XCTAssertEqual(try pendingFiles(), before)
    }
    func testStatusEmptyBodyAndUnapprovedOriginRejected() async throws {
        for path in ["error", "empty"] {
            do { _ = try await BoundedDownload.data(from: url(path), maximumBytes: 128, allowedHosts: ["download.vpnnav.test"], configuration: configuration); XCTFail() } catch {}
        }
        do { _ = try await BoundedDownload.data(from: URL(string: "http://download.vpnnav.test/ok")!, maximumBytes: 128, allowedHosts: ["download.vpnnav.test"], configuration: configuration); XCTFail() }
        catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
    }
    func testHTTPStatusRemainsAvailableToCallers() async throws {
        do {
            _ = try await BoundedDownload.data(from: url("error"), maximumBytes: 128,
                allowedHosts: ["download.vpnnav.test"], configuration: configuration)
            XCTFail("HTTP failure accepted")
        } catch BoundedDownload.Failure.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }
    }
}
