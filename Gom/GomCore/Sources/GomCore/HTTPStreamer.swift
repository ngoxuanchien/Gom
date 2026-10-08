import Foundation
import Synchronization

public enum StreamEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// Routes URLSession delegate callbacks to the stream of the task they belong to.
final class StreamDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let continuations = Mutex<[Int: AsyncThrowingStream<StreamEvent, any Error>.Continuation]>([:])

    private func continuation(for task: URLSessionTask) -> AsyncThrowingStream<StreamEvent, any Error>.Continuation? {
        continuations.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else { return .cancel }
        continuation(for: dataTask)?.yield(.response(http))
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation(for: dataTask)?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = continuations.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }
}

/// Streams a request's response and body in the chunks URLSession delivers them.
/// `URLSession.bytes` is avoided because it yields one byte at a time.
public final class HTTPStreamer: Sendable {
    private let session: URLSession
    private let delegate: StreamDelegate

    public init(configuration: URLSessionConfiguration = .default) {
        // Cookies come only from the request headers the extension supplied.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // DownloadQueue may briefly start a download beside one winding down; none of its requests should queue here.
        configuration.httpMaximumConnectionsPerHost = 2 * connectionsPerHost
        let delegate = StreamDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Paces the downloads that use this streamer (see `runDownload`); one bucket for all of them.
    let limiter = BandwidthLimiter()

    /// Combined download speed cap in bytes/s; 0 = unlimited. Applies to running downloads at once.
    public var bytesPerSecond: Int {
        get { limiter.bytesPerSecond }
        set { limiter.bytesPerSecond = newValue }
    }

    /// ponytail: unbounded buffer, so a disk slower than the network grows memory; add backpressure if that bites.
    public func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            delegate.continuations.withLock { $0[task.taskIdentifier] = continuation }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }
}
