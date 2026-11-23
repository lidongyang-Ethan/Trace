import Foundation

/// All mutable state is protected by `lock`. Snapshots contain only redacted values.
public final class DiagnosticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: DiagnosticsConfiguration
    private var records: [RequestRecord] = []
    private var paused = false
    public init(configuration: DiagnosticsConfiguration = .init()) { self.configuration = configuration.normalized }

    public func snapshot() -> DiagnosticsSnapshot {
        locked { .init(records: records, isPaused: paused, configuration: configuration) }
    }
    /// Returns only a currently retained record; removed records do not fall back to old snapshots.
    public func record(id: UUID) -> RequestRecord? {
        locked { records.first { $0.id == id } }
    }
    public func setPaused(_ value: Bool) { locked { paused = value } }
    public func clear() { locked { records.removeAll(keepingCapacity: true) } }
    public func updateConfiguration(_ value: DiagnosticsConfiguration) {
        locked {
            configuration = value.normalized
            // A rule change invalidates existing snapshots in the store; never re-use less-redacted records.
            records.removeAll(keepingCapacity: true)
        }
    }
    public func begin(id: UUID, at date: Date = Date()) {
        locked {
            guard !paused, !records.contains(where: { $0.id == id }) else { return }
            records.insert(.init(id: id, startedAt: date), at: 0)
            if records.count > configuration.maximumRecords { records.removeLast(records.count - configuration.maximumRecords) }
        }
    }
    public func markRetrying(id: UUID) {
        locked {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].outcome = .running
            records[index].issue = nil
            records[index].finishedAt = nil
        }
    }
    public func captureRequest(id: UUID, request: URLRequest, isNewAttempt: Bool = true) {
        locked {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            let redactor = Redactor(configuration: configuration)
            records[index].method = request.httpMethod ?? "GET"
            records[index].url = redactor.url(request.url)
            records[index].requestHeaders = redactor.headers(request.allHTTPHeaderFields ?? [:])
            records[index].requestBody = redactor.body(request.httpBody, contentType: request.value(forHTTPHeaderField: "Content-Type"), configuration: configuration)
            if isNewAttempt { records[index].attempts += 1 }
            enforceBudget()
        }
    }
    public func finish(id: UUID, response: HTTPURLResponse?, data: Data?, outcome: RequestOutcome,
                       issue: DiagnosticIssue? = nil, at date: Date = Date()) {
        locked {
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            let redactor = Redactor(configuration: configuration)
            let headers = response?.allHeaderFields.reduce(into: [String: String]()) { result, element in
                result[String(describing: element.key)] = String(describing: element.value)
            } ?? [:]
            records[index].statusCode = response?.statusCode
            records[index].responseHeaders = redactor.headers(headers)
            records[index].responseBody = redactor.body(data, contentType: response?.value(forHTTPHeaderField: "Content-Type"), configuration: configuration)
            records[index].finishedAt = date
            // Multiple serializers can observe a single request. Preserve any observed failure.
            if !records[index].outcome.isFailure || outcome.isFailure {
                records[index].outcome = outcome
                records[index].issue = issue
            }
            enforceBudget()
        }
    }
    /// Safe, value-only report. Never reads the original URLRequest or raw body.
    public func report(for record: RequestRecord) -> String {
        var lines = [TraceLocalization.text("Trace · Network diagnostics report"), "\(record.method) \(record.url)",
                     TraceLocalization.format("Result: %@", String(describing: record.outcome.title)), TraceLocalization.format("HTTP: %@", record.statusCode.map(String.init) ?? TraceLocalization.text("No response")),
                     TraceLocalization.format("Total duration: %@", record.duration.map { String(format: "%.0f ms", $0 * 1_000) } ?? TraceLocalization.text("In progress")),
                     TraceLocalization.format("Attempts: %@", String(describing: record.attempts))]
        if let issue = record.issue {
            lines.append(issue.summary)
            if let path = issue.fieldPath { lines.append(TraceLocalization.format("Field path: %@", String(describing: path))) }
            if let expected = issue.expectedType { lines.append(TraceLocalization.format("Expected: %@", String(describing: expected))) }
        }
        lines += ["", TraceLocalization.text("Request headers:")] + record.requestHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
        lines += ["", TraceLocalization.text("Request body:"), record.requestBody.displayText, "", TraceLocalization.text("Response headers:")]
            + record.responseHeaders.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }
        lines += ["", TraceLocalization.text("Response body:"), record.responseBody.displayText]
        return lines.joined(separator: "\n")
    }
    private func enforceBudget() {
        var total = records.reduce(0) { $0 + $1.retainedBodyBytes }
        for index in records.indices.reversed() where total > configuration.maximumTotalBodyBytes {
            let bytes = records[index].retainedBodyBytes
            guard bytes > 0 else { continue }
            total -= bytes
            if records[index].requestBody.text != nil {
                records[index].requestBody = .init(state: .evicted, originalByteCount: records[index].requestBody.originalByteCount)
            }
            if records[index].responseBody.text != nil {
                records[index].responseBody = .init(state: .evicted, originalByteCount: records[index].responseBody.originalByteCount)
            }
        }
    }
    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return operation()
    }
}
