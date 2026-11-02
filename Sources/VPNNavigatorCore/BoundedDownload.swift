import Foundation

/// Counts decoded response bytes as they arrive, including responses without
/// Content-Length. File downloads keep only URLSession's current chunk in memory.
public enum BoundedDownload {
    public enum Failure: Error, LocalizedError {
        case httpStatus(Int)
        public var errorDescription: String? { URLError(.badServerResponse).localizedDescription }
    }
    public static func data(from url: URL, maximumBytes: Int, allowedHosts: Set<String>, timeout: TimeInterval = 30, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let result = try await Request(maximumBytes: maximumBytes, allowedHosts: allowedHosts, timeout: timeout, configuration: configuration).run(url)
        guard case .data(let data) = result else { throw URLError(.unknown) }; return data
    }
    /// The caller owns and must remove the returned private temporary file.
    public static func file(from url: URL, maximumBytes: Int, allowedHosts: Set<String>, timeout: TimeInterval = 300, configuration: URLSessionConfiguration = .ephemeral) async throws -> URL {
        let request = Request(maximumBytes: maximumBytes, allowedHosts: allowedHosts, timeout: timeout, configuration: configuration)
        try request.useFile()
        guard case .file(let file) = try await request.run(url) else { throw URLError(.unknown) }; return file
    }
    private enum Payload { case data(Data), file(URL) }
    private final class Request: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let maximumBytes: Int
        let allowedHosts: Set<String>
        let timeout: TimeInterval
        let configuration: URLSessionConfiguration
        private let lock = NSLock()
        private var bytes = Data()
        private var count = 0
        private var file: URL?
        private var handle: FileHandle?
        private var session: URLSession?
        private var deadline: DispatchWorkItem?
        private var reply: CheckedContinuation<Payload, Error>?
        private var result: Result<Payload, Error>?
        init(maximumBytes: Int, allowedHosts: Set<String>, timeout: TimeInterval, configuration: URLSessionConfiguration) {
            self.configuration = configuration
            self.maximumBytes = maximumBytes; self.allowedHosts = allowedHosts; self.timeout = timeout
        }
        func useFile() throws {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-download-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ProfileFileIO.Failure.cannotWrite }
            do { handle = try FileHandle(forWritingTo: path); file = path }
            catch { try? FileManager.default.removeItem(at: path); throw error }
        }
        func allowed(_ url: URL?) -> Bool { url.map { $0.scheme == "https" && allowedHosts.contains($0.host?.lowercased() ?? "") && $0.user == nil && $0.password == nil && ($0.port == nil || $0.port == 443) } ?? false }
        func run(_ url: URL) async throws -> Payload {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if let result { lock.unlock(); continuation.resume(with: result); return }
                    reply = continuation
                    guard maximumBytes > 0, timeout > 0, timeout.isFinite, allowed(url) else {
                        lock.unlock(); finish(.failure(URLError(.badURL))); return
                    }
                    let configuration = self.configuration.copy() as! URLSessionConfiguration
                    configuration.timeoutIntervalForRequest = min(timeout, 30)
                    configuration.timeoutIntervalForResource = timeout
                    configuration.httpCookieStorage = nil
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                    self.deadline = deadline
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                    session.dataTask(with: url).resume()
                    lock.unlock()
                }
            } onCancel: { self.finish(.failure(CancellationError())) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard allowed(response.url), let http = response as? HTTPURLResponse else {
                completionHandler(.cancel); finish(.failure(URLError(.badServerResponse))); return
            }
            guard http.statusCode == 200 else {
                completionHandler(.cancel); finish(.failure(Failure.httpStatus(http.statusCode))); return
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                completionHandler(.cancel); finish(.failure(ProfileFileIO.Failure.tooLarge)); return
            }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            guard data.count <= maximumBytes - count else {
                lock.unlock(); finish(.failure(ProfileFileIO.Failure.tooLarge)); return
            }
            do {
                if let handle { try handle.write(contentsOf: data) } else { bytes.append(data) }
                count += data.count; lock.unlock()
            } catch { lock.unlock(); finish(.failure(error)) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)); return }
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            let payload = file.map(Payload.file) ?? .data(bytes)
            let nonempty = count > 0
            lock.unlock()
            finish(nonempty ? .success(payload) : .failure(URLError(.zeroByteResource)))
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let accepted = allowed(request.url)
            completionHandler(accepted ? request : nil)
            if !accepted { finish(.failure(URLError(.redirectToNonExistentLocation))) }
        }
        private func finish(_ value: Result<Payload, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let reply = self.reply; self.reply = nil
            let session = self.session; self.session = nil
            deadline?.cancel(); deadline = nil
            try? handle?.close(); handle = nil
            if case .failure = value, let file { try? FileManager.default.removeItem(at: file) }
            bytes.removeAll(keepingCapacity: false)
            lock.unlock()
            session?.invalidateAndCancel(); reply?.resume(with: value)
        }
        deinit { try? handle?.close() }
    }
}
