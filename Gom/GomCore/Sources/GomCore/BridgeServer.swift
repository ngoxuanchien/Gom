import Foundation
import Network

/// Loopback-only HTTP endpoint for the browser extension.
/// @unchecked: the listener and its connections are only touched on `queue`.
public final class BridgeServer: @unchecked Sendable {
    private let listener: NWListener
    private let token: String
    private let onAdd: @Sendable (AddRequest) -> Void
    private let queue = DispatchQueue(label: "gom.bridge")

    public init(port: UInt16, token: String, onAdd: @escaping @Sendable (AddRequest) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.token = token
        self.onAdd = onAdd
    }

    /// Starts listening and returns the bound port (useful when `port` was 0).
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch parseHTTPRequest(buffer) {
            case .incomplete where !isComplete && error == nil:
                receive(connection, buffer: buffer)
            case .complete(let request):
                let (response, add) = route(request, token: token)
                if let add { onAdd(add) }
                send(response, on: connection)
            case .incomplete, .invalid, .tooLarge:
                send(HTTPResponse(status: 400, json: #"{"ok":false,"error":"bad request"}"#), on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
