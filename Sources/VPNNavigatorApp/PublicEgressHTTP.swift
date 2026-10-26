import Foundation
import CFNetwork
import VPNNavigatorCore

/// A fresh bounded session for each user-triggered family query. Production
/// endpoints are fixed HTTPS URLs; no profile or credential data is accepted.
enum PublicEgressHTTP {
    static func query(_ family: EgressFamily) async throws -> EgressHTTPResult {
        try await EgressHTTPRequest(family: family, url: family.endpoint, timeout: 8).run()
    }
    static func loopbackFixture(_ family: EgressFamily, url: URL, timeout: Double = 8) async throws -> EgressHTTPResult {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", url.scheme == "http",
              ["127.0.0.1", "[::1]", "::1"].contains(url.host ?? ""), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path == "/", (0.1...8).contains(timeout) else { throw EgressProbeFailure.invalidResponse }
        return try await EgressHTTPRequest(family: family, url: url, timeout: timeout).run()
    }
}

private final class EgressHTTPRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let family: EgressFamily
    private let url: URL
    private let timeout: Double
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EgressHTTPResult, Error>?
    private var completed: Result<EgressHTTPResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    private var bytes = Data()
    private var responseAccepted = false
    private var remote: String?
    private var proxy: Bool?
    private var cache: Bool?
    private var began = ProcessInfo.processInfo.systemUptime

    init(family: EgressFamily, url: URL, timeout: Double) { self.family = family; self.url = url; self.timeout = timeout }
    func run() async throws -> EgressHTTPResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { start($0) }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }
    private func start(_ continuation: CheckedContinuation<EgressHTTPResult, Error>) {
        lock.lock()
        if let completed { lock.unlock(); continuation.resume(with: completed); return }
        self.continuation = continuation; began = ProcessInfo.processInfo.systemUptime
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = min(5, timeout); configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false; configuration.httpMaximumConnectionsPerHost = 1
        // Preserve OS routing (including utun), but do not intentionally send a
        // route diagnostic through the system HTTP/PAC/SOCKS proxy configuration.
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0, kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: min(5, timeout))
        request.httpMethod = "GET"; request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let task = session.dataTask(with: request)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(EgressProbeFailure.timeout)) }
        self.session = session; self.task = task; self.timer = timer
        lock.unlock(); timer.resume(); task.resume()
    }
    private func finish(_ value: Result<EgressHTTPResult, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = value
        let continuation = self.continuation, session = self.session, timer = self.timer
        self.continuation = nil; self.session = nil; self.task = nil; self.timer = nil; bytes = Data()
        lock.unlock()
        timer?.cancel(); session?.invalidateAndCancel(); continuation?.resume(with: value)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.url == url else { completionHandler(.cancel); finish(.failure(EgressProbeFailure.invalidResponse)); return }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(http.statusCode == 401 || http.statusCode == 407 ? EgressProbeFailure.authentication : EgressProbeFailure.httpStatus)); return
        }
        guard response.expectedContentLength <= Int64(PublicEgressAddress.maximumBytes) else { completionHandler(.cancel); finish(.failure(EgressProbeFailure.tooLarge)); return }
        lock.lock(); responseAccepted = completed == nil; let allow = responseAccepted; lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        guard bytes.count + data.count <= PublicEgressAddress.maximumBytes else { lock.unlock(); finish(.failure(EgressProbeFailure.tooLarge)); return }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No requests to a redirected provider or a local-network destination.
        completionHandler(nil); finish(.failure(EgressProbeFailure.redirect))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil); finish(.failure(EgressProbeFailure.authentication)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        guard completed == nil, let transaction = metrics.transactionMetrics.last else { return }
        remote = transaction.remoteAddress.flatMap(IPAddress.canonical)
        proxy = transaction.isProxyConnection
        switch transaction.resourceFetchType {
        case .networkLoad: cache = false
        case .localCache: cache = true
        default: cache = nil
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        let data = bytes, accepted = responseAccepted, remote = self.remote, proxy = self.proxy, cache = self.cache, began = self.began
        lock.unlock()
        if let error {
            finish(.failure((error as? URLError)?.code == .timedOut ? EgressProbeFailure.timeout : EgressProbeFailure.transport)); return
        }
        guard accepted else { finish(.failure(EgressProbeFailure.invalidResponse)); return }
        do {
            let address = try PublicEgressAddress.parse(data, family: family)
            finish(.success(.init(address: address, remoteAddress: remote, usedProxy: proxy, cacheHit: cache,
                milliseconds: max(0, (ProcessInfo.processInfo.systemUptime - began) * 1000))))
        } catch { finish(.failure(error)) }
    }
}
