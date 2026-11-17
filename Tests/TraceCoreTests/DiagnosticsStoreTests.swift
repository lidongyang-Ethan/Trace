import Foundation
import Testing
@testable import TraceCore

private let response = HTTPURLResponse(url: URL(string: "https://trace.invalid/test")!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json", "Set-Cookie": "private-cookie"])!

@Test func secretsAreRedactedBeforeStorageAndExport() throws {
    let store = DiagnosticsStore()
    let id = UUID()
    store.begin(id: id)
    var request = URLRequest(url: URL(string: "https://username:pass@trace.invalid/login?token=query-secret&page=1#private")!)
    request.httpMethod = "POST"
    request.setValue("Bearer auth-secret", forHTTPHeaderField: "Authorization")
    request.setValue("cookie-secret", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"password":"request-secret","nested":[{"email":"personal@test.invalid"}],"name":"Visible"}"#.utf8)
    store.captureRequest(id: id, request: request)
    store.finish(id: id, response: response, data: Data(#"{"accessToken":"response-secret","id":42}"#.utf8), outcome: .success)
    let record = try #require(store.snapshot().records.first)
    let report = store.report(for: record)
    for secret in ["username", "pass@", "query-secret", "auth-secret", "cookie-secret", "private-cookie", "request-secret", "personal@test.invalid", "response-secret", "#private"] {
        #expect(!report.contains(secret), "Leaked: \(secret)")
    }
    #expect(report.contains("Visible"))
    #expect(report.contains("page=1"))
    #expect(record.responseHeaders["Set-Cookie"] == TraceLocalization.text("[REDACTED]"))
}

@Test func unsafeBodiesAreOmittedRatherThanPartiallyRedacted() {
    let config = DiagnosticsConfiguration(maximumBodyBytes: 64)
    let redactor = Redactor(configuration: config)
    for (body, type) in [
        (#"{"password":"broken-secret""#, "application/json"),
        ("password=plain-secret", "text/plain"),
        (String(repeating: "secret", count: 100), "application/json")
    ] {
        let result = redactor.body(Data(body.utf8), contentType: type, configuration: config)
        #expect(result.state == .omitted)
        #expect(result.text == nil)
    }
}

@Test func pauseAdmitsNoNewRecordsButCompletesExistingOnes() throws {
    let store = DiagnosticsStore()
    let first = UUID(), ignored = UUID()
    store.begin(id: first)
    store.setPaused(true)
    store.begin(id: ignored)
    store.finish(id: first, response: response, data: nil, outcome: .success)
    #expect(store.snapshot().records.count == 1)
    #expect(try #require(store.snapshot().records.first).outcome == .success)
    store.setPaused(false)
    store.begin(id: ignored)
    #expect(store.snapshot().records.count == 2)
}

@Test func clearDoesNotResurrectLateResponses() {
    let store = DiagnosticsStore()
    let id = UUID()
    store.begin(id: id)
    store.clear()
    store.finish(id: id, response: response, data: Data("{}".utf8), outcome: .success)
    #expect(store.snapshot().records.isEmpty)
}

@Test func capacityEvictsOldRecordsAndOldBodies() throws {
    let store = DiagnosticsStore(configuration: .init(maximumRecords: 2, maximumTotalBodyBytes: 35))
    let ids = [UUID(), UUID(), UUID()]
    for id in ids {
        store.begin(id: id)
        store.finish(id: id, response: response, data: Data(#"{"value":"hello"}"#.utf8), outcome: .success)
    }
    let records = store.snapshot().records
    #expect(records.map(\.id) == [ids[2], ids[1]])
    #expect(records.reduce(0) { $0 + $1.retainedBodyBytes } <= 35)
    #expect(records[1].responseBody.state == .evicted)
    #expect(records[0].responseBody.state == .json)
}

@Test func failuresSurviveOtherSerializersAndRetryCanRecover() throws {
    let store = DiagnosticsStore()
    let id = UUID()
    store.begin(id: id)
    store.finish(id: id, response: response, data: nil, outcome: .decodingError, issue: .init(summary: "failure"))
    store.finish(id: id, response: response, data: nil, outcome: .success)
    #expect(try #require(store.snapshot().records.first).outcome == .decodingError)
    store.markRetrying(id: id)
    #expect(try #require(store.snapshot().records.first).outcome == .running)
    store.finish(id: id, response: response, data: nil, outcome: .success)
    #expect(try #require(store.snapshot().records.first).outcome == .success)
}

@Test func concurrentRequestsStayIsolatedAndBounded() async {
    let store = DiagnosticsStore(configuration: .init(maximumRecords: 20))
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                let id = UUID()
                store.begin(id: id)
                var request = URLRequest(url: URL(string: "https://trace.invalid/\(index)")!)
                request.httpMethod = "GET"
                store.captureRequest(id: id, request: request)
                store.finish(id: id, response: response, data: Data("{}".utf8), outcome: .success)
            }
        }
    }
    let records = store.snapshot().records
    #expect(records.count == 20)
    #expect(Set(records.map(\.id)).count == 20)
    #expect(records.allSatisfy { $0.outcome == .success && $0.method == "GET" })
}

@Test func configurationChangesClearOldDataAndDisableBodies() throws {
    let store = DiagnosticsStore()
    store.begin(id: UUID())
    store.updateConfiguration(.init(capturesBodies: false))
    #expect(store.snapshot().records.isEmpty)
    let id = UUID()
    store.begin(id: id)
    store.finish(id: id, response: response, data: Data("{}".utf8), outcome: .success)
    #expect(try #require(store.snapshot().records.first).responseBody.state == .disabled)
}
