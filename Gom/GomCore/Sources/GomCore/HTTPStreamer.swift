import Foundation
import Synchronization

public enum StreamEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// Routes URLSession delegate callbacks to the stream of the task they belong to.
final class StreamDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let continuations = Mutex<[Int: AsyncThrowingStream<StreamEvent, any Error>.Continuation]>([:])

    /// Token bucket shared by every task of the session, kept as a GCRA reservation clock.
    struct Throttle {
        var bytesPerSecond = 0   // 0 = unlimited
        var nextFree = ContinuousClock.now
        var lastToken = 0
        var suspended: [Int: (task: URLSessionTask, token: Int)] = [:]
    }
    let throttle = Mutex(Throttle())
    static let burst = Duration.milliseconds(250)

    /// New rate applies at once: tasks waiting out a delay computed at the old rate resume now.
    func setRate(_ bytesPerSecond: Int) {
        throttle.withLock { t in
            t.bytesPerSecond = max(0, bytesPerSecond)
            t.nextFree = .now
            for entry in t.suspended.values { entry.task.resume() }
            t.suspended = [:]
        }
    }

    /// ponytail: suspend() doesn't stop socket read-ahead, so speed is bursty (average holds);
    /// a pull-based HTTP client (Network.framework) would pace smoothly if that matters.
    /// Charges `bytes` to the bucket; when overdrawn, suspends `task` so URLSession stops
    /// reading its socket until the debt is paid.
    private func charge(_ bytes: Int, to task: URLSessionTask) {
        let wait: (seconds: Double, token: Int)? = throttle.withLock { t in
            guard t.bytesPerSecond > 0 else { return nil }
            let now = ContinuousClock.now
            t.nextFree = max(now - Self.burst, t.nextFree) + .seconds(Double(bytes) / Double(t.bytesPerSecond))
            guard t.nextFree > now else { return nil }
            // URLSession still delivers already-buffered data to a suspended task. suspend() calls
            // are counted, so suspend only once and let the latest timer's single resume() win.
            let alreadySuspended = t.suspended[task.taskIdentifier] != nil
            t.lastToken += 1
            t.suspended[task.taskIdentifier] = (task, t.lastToken)
            if !alreadySuspended { task.suspend() }   // inside the lock so setRate can't resume it first
            return ((t.nextFree - now) / .seconds(1), t.lastToken)
        }
        guard let wait else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait.seconds) { [self] in
            throttle.withLock { t in
                // Skip if setRate already resumed it, or the task finished.
                guard t.suspended[task.taskIdentifier]?.token == wait.token else { return }
                t.suspended[task.taskIdentifier] = nil
                task.resume()
            }
        }
    }

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
        charge(data.count, to: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        throttle.withLock { _ = $0.suspended.removeValue(forKey: task.taskIdentifier) }
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
        let delegate = StreamDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Combined download speed cap for every request of this streamer, in bytes/s; 0 = unlimited.
    /// Takes effect immediately, including for requests in flight.
    public var bytesPerSecond: Int {
        get { delegate.throttle.withLock { $0.bytesPerSecond } }
        set { delegate.setRate(newValue) }
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
