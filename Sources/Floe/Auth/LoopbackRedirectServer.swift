import Foundation
import Network

/// One-shot HTTP listener on the loopback interface that catches the OAuth
/// redirect (`GET <path>?code=…&state=…`) and answers with a small page.
/// `@unchecked Sendable`: its mutable state is only touched on `queue`.
final class LoopbackRedirectServer: @unchecked Sendable {
    enum Failure: LocalizedError {
        case portUnavailable(UInt16, String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .portUnavailable(port, reason): "Can't listen on 127.0.0.1:\(port) (\(reason))."
            case .timedOut: "Login timed out."
            }
        }
    }

    private let port: UInt16
    private let path: String
    private let listener: NWListener
    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "com.antonchurchyn.floe.oauth-loopback")
    private var ready: CheckedContinuation<Void, Error>?
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?

    init(port: UInt16, path: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure.portUnavailable(port, "invalid port")
        }
        listener = try NWListener(using: parameters, on: nwPort)
        self.port = port
        self.path = path
    }

    /// Starts listening; returns once the port is bound (call before opening the browser).
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        ready?.resume()
                        ready = nil
                    case let .failed(error), let .waiting(error):
                        let failure = Failure.portUnavailable(port, error.localizedDescription)
                        ready?.resume(throwing: failure)
                        ready = nil
                        finish(.failure(failure))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    /// Waits for the redirect and returns its query parameters.
    func redirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result {
                        continuation.resume(with: result)
                        return
                    }
                    waiter = continuation
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(Failure.timedOut))
                    }
                }
            }
        } onCancel: {
            queue.async { [self] in finish(.failure(CancellationError())) }
        }
    }

    // MARK: - Private (on `queue`)

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            // Request line: "GET /login?code=…&state=… HTTP/1.1"
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: target), components.path == path else {
                return respond(connection, status: "404 Not Found", html: "")
            }
            let query = Dictionary(
                (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            let succeeded = query["code"] != nil
            respond(connection, status: "200 OK", html: Self.page(succeeded: succeeded))
            finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = outcome
        listener.cancel()
        waiter?.resume(with: outcome)
        waiter = nil
    }

    private static func page(succeeded: Bool) -> String {
        let message = succeeded
            ? "Tint is connected to Spotify. You can close this tab."
            : "Login was cancelled. You can close this tab and try again in Tint."
        return """
        <!doctype html><meta charset="utf-8"><title>Tint</title>
        <body style="font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh;\
        background:#121212;color:#eee"><p>\(message)</p></body>
        """
    }
}
