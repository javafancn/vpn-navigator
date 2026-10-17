import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded streaming download. Reject a large response while receiving it,
/// rather than first allocating an unbounded Data in URLSession.shared.
final class RuleFeedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var reply: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var session: URLSession?
    static func fetch(_ url: URL) async throws -> Data {
        let request = RuleFeedRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start(url, reply: $0) }
        } onCancel: { request.finish(.failure(CancellationError())) }
    }
    private func start(_ url: URL, reply: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { lock.unlock(); reply.resume(with: result); return }
        self.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var input = URLRequest(url: url)
        input.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: input).resume()
        lock.unlock()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 2_000_000 else {
            completionHandler(.cancel); finish(.failure(RuleError.tooLarge)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        guard bytes.count + data.count < 2_000_000 else {
            lock.unlock(); finish(.failure(RuleError.tooLarge)); return
        }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let data = bytes; lock.unlock()
        finish(.success(data))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.map { $0.scheme == "https" && ["raw.githubusercontent.com", "api.github.com"].contains($0.host ?? "") } ?? false
        completionHandler(allowed ? request : nil)
        if !allowed { finish(.failure(URLError(.redirectToNonExistentLocation))) }
    }
    private func finish(_ value: Result<Data, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let reply = self.reply; self.reply = nil
        let session = self.session; self.session = nil
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel(); reply?.resume(with: value)
    }
}
