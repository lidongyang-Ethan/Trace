import Foundation

public struct DiagnosticsConfiguration: Sendable {
    public var maximumRecords: Int
    public var maximumBodyBytes: Int
    public var maximumTotalBodyBytes: Int
    public var capturesBodies: Bool
    public var sensitiveKeys: Set<String>

    public init(maximumRecords: Int = 200, maximumBodyBytes: Int = 65_536,
                maximumTotalBodyBytes: Int = 8 * 1_024 * 1_024, capturesBodies: Bool = true,
                sensitiveKeys: Set<String> = ["password", "token", "accessToken", "refreshToken", "email", "apiKey", "secret", "signature"]) {
        self.maximumRecords = max(1, maximumRecords)
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.maximumTotalBodyBytes = max(0, maximumTotalBodyBytes)
        self.capturesBodies = capturesBodies
        self.sensitiveKeys = Set(sensitiveKeys.map { $0.lowercased() })
    }
}

public enum RequestOutcome: String, Sendable, Codable {
    case running, success, httpError, decodingError, networkError, cancelled
    public var title: String {
        switch self {
        case .running: TraceLocalization.text("In progress")
        case .success: TraceLocalization.text("Success")
        case .httpError: TraceLocalization.text("HTTP error")
        case .decodingError: TraceLocalization.text("Decoding failed")
        case .networkError: TraceLocalization.text("Network error")
        case .cancelled: TraceLocalization.text("Cancelled")
        }
    }
    public var isFailure: Bool { [.httpError, .decodingError, .networkError].contains(self) }
}

public struct CapturedBody: Sendable, Equatable {
    public enum State: String, Sendable { case json, absent, disabled, omitted, evicted }
    public let state: State
    public let text: String?
    public let originalByteCount: Int?
    public var retainedByteCount: Int { text?.utf8.count ?? 0 }
    public var displayText: String {
        if let text { return text }
        switch state {
        case .json: return TraceLocalization.text("No content")
        case .absent: return TraceLocalization.text("No body / body unavailable")
        case .disabled: return TraceLocalization.text("Body capture disabled")
        case .omitted: return TraceLocalization.text("Body omitted: unsupported format, unsafe to redact, or size limit exceeded")
        case .evicted: return TraceLocalization.text("Body removed to stay within the total storage limit")
        }
    }
    public init(state: State, text: String? = nil, originalByteCount: Int? = nil) {
        self.state = state; self.text = text; self.originalByteCount = originalByteCount
    }
}

public struct DiagnosticIssue: Sendable, Equatable {
    public let summary: String
    public let fieldPath: String?
    public let expectedType: String?
    public init(summary: String, fieldPath: String? = nil, expectedType: String? = nil) {
        self.summary = summary; self.fieldPath = fieldPath; self.expectedType = expectedType
    }
}

public struct RequestRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public internal(set) var finishedAt: Date?
    public internal(set) var method: String = "—"
    public internal(set) var url: String = TraceLocalization.text("Waiting for request URL")
    public internal(set) var requestHeaders: [String: String] = [:]
    public internal(set) var responseHeaders: [String: String] = [:]
    public internal(set) var requestBody = CapturedBody(state: .absent)
    public internal(set) var responseBody = CapturedBody(state: .absent)
    public internal(set) var statusCode: Int?
    public internal(set) var outcome: RequestOutcome = .running
    public internal(set) var issue: DiagnosticIssue?
    public internal(set) var attempts: Int = 0
    public var duration: TimeInterval? { finishedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    public var path: String { URLComponents(string: url)?.path.nonEmpty ?? url }
    public var host: String { URLComponents(string: url)?.host ?? "—" }
    public var retainedBodyBytes: Int { requestBody.retainedByteCount + responseBody.retainedByteCount }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

public struct DiagnosticsSnapshot: Sendable {
    public let records: [RequestRecord]
    public let isPaused: Bool
    public let configuration: DiagnosticsConfiguration
}
