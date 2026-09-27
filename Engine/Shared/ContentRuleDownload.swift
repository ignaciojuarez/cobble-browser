import Foundation

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func downloadContentRules(from source: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
    var request = URLRequest(url: source)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
          response.url == source else { throw EngineError.notReady(String(localized: "The update source did not return its selected HTTPS address.")) }
    guard response.expectedContentLength <= Int64(1_000_000) else {
        throw EngineError.notReady(String(localized: "The update file is larger than 1 MB."))
    }
    var data = Data()
    for try await byte in bytes {
        guard data.count < 1_000_000 else { throw EngineError.notReady(String(localized: "The update file is larger than 1 MB.")) }
        data.append(byte)
    }
    guard let json = String(data: data, encoding: .utf8) else {
        throw EngineError.notReady(String(localized: "The update file is not UTF-8 JSON."))
    }
    return json
}
