import Alamofire
import Foundation
import Testing
import TraceAlamofire
import TraceCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "trace.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let firstRetry = path == "/retry" && request.value(forHTTPHeaderField: "X-Attempt") != "1"
        let status = path == "/http" ? 401 : firstRetry ? 503 : 200
        let body = path == "/decode" ? #"{"items":[{"title":null}]}"# : #"{"items":[{"title":"Hello"}],"accessToken":"response-secret"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct Feed: Decodable, Sendable {
    struct Item: Decodable, Sendable { let title: String }
    let items: [Item]
}
private struct RetryHeader: RequestInterceptor {
    func retry(_ request: Request, for session: Session, dueTo error: any Error, completion: @escaping @Sendable (RetryResult) -> Void) {
        completion(request.retryCount == 0 ? .retry : .doNotRetry)
    }
}
private func makeSession(_ diagnostics: NetworkDiagnostics) -> Session {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return Session(configuration: configuration, eventMonitors: [diagnostics.monitor])
}
private func settle(_ diagnostics: NetworkDiagnostics) async {
    await withCheckedContinuation { continuation in diagnostics.monitor.queue.async { continuation.resume() } }
}

@Test func observesSuccessHTTPFailureAndDecodingPath() async throws {
    let diagnostics = NetworkDiagnostics()
    let session = makeSession(diagnostics)
    for path in ["/success", "/http", "/decode"] {
        _ = await session.request("https://trace.invalid\(path)?token=query-secret", headers: [.authorization(bearerToken: "auth-secret")])
            .validate().serializingDecodable(Feed.self).response
    }
    await settle(diagnostics)
    let records = diagnostics.store.snapshot().records
    #expect(records.count == 3)
    #expect(records.first(where: { $0.path == "/success" })?.outcome == .success)
    #expect(records.first(where: { $0.path == "/http" })?.outcome == .httpError)
    let decode = try #require(records.first(where: { $0.path == "/decode" }))
    #expect(decode.outcome == .decodingError)
    #expect(decode.issue?.fieldPath == "items[0].title")
    #expect(decode.issue?.expectedType == "String")
    #expect(records.allSatisfy { $0.attempts == 1 && $0.duration != nil })
    for record in records {
        let report = diagnostics.store.report(for: record)
        #expect(!report.contains("query-secret"))
        #expect(!report.contains("auth-secret"))
        #expect(!report.contains("response-secret"))
    }
}

@Test func observesTimeoutAndExplicitCancellation() async throws {
    let diagnostics = NetworkDiagnostics()
    let session = makeSession(diagnostics)
    _ = await session.request("https://trace.invalid/timeout").serializingData().response
    let cancelled = session.request("https://trace.invalid/cancel")
    cancelled.cancel()
    _ = await cancelled.serializingData().response
    await settle(diagnostics)
    let records = diagnostics.store.snapshot().records
    #expect(records.contains { $0.path == "/timeout" && $0.outcome == .networkError })
    #expect(records.contains { $0.outcome == .cancelled })
    #expect(!records.contains { $0.outcome == .running })
}

@Test func concurrentRequestsProduceDistinctRecords() async {
    let diagnostics = NetworkDiagnostics()
    let session = makeSession(diagnostics)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<10 {
            group.addTask {
                _ = await session.request("https://trace.invalid/success/\(index)").validate().serializingDecodable(Feed.self).response
            }
        }
    }
    await settle(diagnostics)
    let records = diagnostics.store.snapshot().records
    #expect(records.count == 10)
    #expect(Set(records.map(\.path)).count == 10)
    #expect(records.allSatisfy { $0.outcome == .success && $0.attempts == 1 })
}

@Test func retryRetainsOneRecordAndFinalOutcome() async throws {
    // This endpoint fails on every attempt, exercising retry accounting without mutable stub state.
    let diagnostics = NetworkDiagnostics()
    let session = makeSession(diagnostics)
    _ = await session.request("https://trace.invalid/http", interceptor: RetryHeader())
        .validate().serializingDecodable(Feed.self).response
    await settle(diagnostics)
    let record = try #require(diagnostics.store.snapshot().records.first)
    #expect(diagnostics.store.snapshot().records.count == 1)
    #expect(record.attempts == 2)
    #expect(record.outcome == .httpError)
}

private final class RecoverOnce: RequestInterceptor, @unchecked Sendable {
    private let lock = NSLock()
    private var attempt = 0
    func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping @Sendable (Result<URLRequest, any Error>) -> Void) {
        lock.lock(); let current = attempt; attempt += 1; lock.unlock()
        var request = urlRequest
        request.setValue(String(current), forHTTPHeaderField: "X-Attempt")
        completion(.success(request))
    }
    func retry(_ request: Request, for session: Session, dueTo error: any Error, completion: @escaping @Sendable (RetryResult) -> Void) {
        completion(request.retryCount == 0 ? .retry : .doNotRetry)
    }
}

@Test func successfulRetryReplacesPreviousFailure() async throws {
    let diagnostics = NetworkDiagnostics()
    let session = makeSession(diagnostics)
    _ = await session.request("https://trace.invalid/retry", interceptor: RecoverOnce())
        .validate().serializingDecodable(Feed.self).response
    await settle(diagnostics)
    let record = try #require(diagnostics.store.snapshot().records.first)
    #expect(diagnostics.store.snapshot().records.count == 1)
    #expect(record.attempts == 2)
    #expect(record.statusCode == 200)
    #expect(record.outcome == .success)
    #expect(record.issue == nil)
}
