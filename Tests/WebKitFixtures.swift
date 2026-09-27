import WebKit
import Network
@testable import Cobble

// Native integration fixtures are the only tests allowed to inspect SDK objects.
@MainActor extension AppModel {
    convenience init(store: SessionStore, websiteDataStoreOverride: WKWebsiteDataStore) {
        self.init(store: store, engines: EngineRegistry([
            WebKitEngine(directory: store.directory, dataStoreOverride: websiteDataStoreOverride)
        ]))
    }
    var websiteDataStoreOverride: WKWebsiteDataStore? {
        (engines.engine(.webKit) as? WebKitEngine)?.dataStoreOverride
    }
}

/// Throttled local HTTP range server for WKDownload pause/resume qualification.
@MainActor final class ResumableHTTPFixture {
    let bytes = Data(repeating: 0x5A, count: 8 * 1_024 * 1_024)
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var rangeOffsets: [Int] = []
    private(set) var requestCount = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, accumulated: Data())
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    func url() -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/resume.bin")! }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { connection.cancel(); return }
                let request = accumulated + (data ?? Data())
                guard request.count < 65_536, let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { connection.cancel() } else { self.receive(connection, accumulated: request) }
                    return
                }
                let lines = String(decoding: request[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
                let offset = range.flatMap { line -> Int? in
                    guard let bytes = line.range(of: "bytes="), let dash = line[bytes.upperBound...].firstIndex(of: "-") else { return nil }
                    return Int(line[bytes.upperBound..<dash])
                } ?? 0
                guard lines.first?.hasPrefix("GET ") == true, offset >= 0, offset < self.bytes.count else { connection.cancel(); return }
                self.requestCount += 1
                if range != nil { self.rangeOffsets.append(offset) }
                let body = self.bytes.suffix(from: offset)
                var header = offset == 0 ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
                header += "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=resume.bin\r\nAccept-Ranges: bytes\r\nETag: \"cobble-resume-v1\"\r\n"
                if offset > 0 { header += "Content-Range: bytes \(offset)-\(self.bytes.count - 1)/\(self.bytes.count)\r\n" }
                header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { self?.send(body, on: connection, offset: 0) }
                })
            }
        }
    }

    private func send(_ body: Data.SubSequence, on connection: NWConnection, offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        let start = body.index(body.startIndex, offsetBy: offset)
        let end = body.index(start, offsetBy: min(65_536, body.distance(from: start, to: body.endIndex)))
        connection.send(content: body[start..<end], completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                MainActor.assumeIsolated { self?.send(body, on: connection, offset: offset + 65_536) }
            }
        })
    }
}

@MainActor extension BrowserPage {
    var webView: WKWebView { (self as! WebKitPage).webView }
}

// HTTP is needed for redirects and form methods; custom WKURLSchemeHandler URLs
// do not exercise WebKit's HTTP transport. Every connection serves one request.
@MainActor final class LocalHTTPFixture {
    struct Request {
        let method: String
        let path: String
        let body: String
        var headers: [String: String] = [:]
    }
    struct Response {
        var status = "200 OK"
        var headers: [String: String] = [:]
        // nil leaves the request pending until stop(), for loading/stop tests.
        var body: String? = ""
        var data: Data? = nil
        var disconnect = false
    }
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let respond: (Request) -> Response
    private(set) var requests: [Request] = []

    init(respond: @escaping (Request) -> Response) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, accumulated: Data())
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        self?.listener.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        self?.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                let bytes = accumulated + (data ?? Data())
                guard bytes.count < 1_048_576, error == nil else { connection.cancel(); return }
                guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { connection.cancel() }
                    else { self.receive(connection, accumulated: bytes) }
                    return
                }
                let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard bytes.count - boundary.upperBound >= length else {
                    if complete { connection.cancel() }
                    else { self.receive(connection, accumulated: bytes) }
                    return
                }
                let firstLine = lines[0].split(separator: " ")
                guard firstLine.count >= 2 else { connection.cancel(); return }
                let request = Request(method: String(firstLine[0]), path: String(firstLine[1]),
                    body: String(decoding: bytes[boundary.upperBound..<(boundary.upperBound + length)], as: UTF8.self),
                    headers: lines.dropFirst().reduce(into: [:]) { headers, line in
                        guard let colon = line.firstIndex(of: ":") else { return }
                        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    })
                self.requests.append(request)
                let response = self.respond(request)
                if response.disconnect { connection.cancel(); return }
                guard let responseBody = response.body else { return }
                let body = response.data ?? Data(responseBody.utf8)
                var headers = response.headers
                headers["Content-Length"] = String(body.count)
                headers["Connection"] = "close"
                if headers["Content-Type"] == nil { headers["Content-Type"] = "text/html; charset=utf-8" }
                let head = "HTTP/1.1 \(response.status)\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
