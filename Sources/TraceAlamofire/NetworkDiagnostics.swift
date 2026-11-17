import Alamofire
import Foundation
import TraceCore

public final class NetworkDiagnostics: Sendable {
    public let store: DiagnosticsStore
    public let monitor: DiagnosticsEventMonitor
    public init(configuration: DiagnosticsConfiguration = .init()) {
        let store = DiagnosticsStore(configuration: configuration)
        self.store = store
        self.monitor = DiagnosticsEventMonitor(store: store)
    }
}

/// Event callbacks are serialized on a dedicated queue. No raw payloads are retained here.
public final class DiagnosticsEventMonitor: EventMonitor, @unchecked Sendable {
    // Only accessed on the serial EventMonitor queue. Metadata only, removed at finish.
    private var observed = Set<UUID>()
    public let queue = DispatchQueue(label: "dev.trace.alamofire.events", qos: .utility)
    public let store: DiagnosticsStore
    public init(store: DiagnosticsStore) { self.store = store }

    public func requestDidResume(_ request: Request) {
        guard isSupported(request) else { return }
        observed.insert(request.id)
        store.begin(id: request.id)
        if let urlRequest = request.request { store.captureRequest(id: request.id, request: urlRequest, isNewAttempt: false) }
    }
    public func requestDidCancel(_ request: Request) {
        guard isSupported(request) else { return }
        // Immediate cancellation can precede requestDidResume. Already-observed requests
        // must not be re-admitted after the user clears the store.
        if observed.insert(request.id).inserted { store.begin(id: request.id) }
        if let urlRequest = request.request { store.captureRequest(id: request.id, request: urlRequest, isNewAttempt: false) }
        store.finish(id: request.id, response: request.response, data: nil,
                     outcome: .cancelled, issue: .init(summary: TraceLocalization.text("Request cancelled by the caller")))
    }
    public func request(_ request: Request, didCreateTask task: URLSessionTask) {
        guard isSupported(request), let urlRequest = task.originalRequest else { return }
        store.captureRequest(id: request.id, request: urlRequest)
    }
    public func requestIsRetrying(_ request: Request) {
        guard isSupported(request) else { return }
        store.markRetrying(id: request.id)
    }
    public func requestDidFinish(_ request: Request) {
        guard isSupported(request), let dataRequest = request as? DataRequest else { return }
        capture(dataRequest, urlRequest: request.request, response: request.response, data: dataRequest.data, error: request.error)
        observed.remove(request.id)
    }
    public func request(_ request: DataRequest, didParseResponse response: DataResponse<Data?, AFError>) {
        capture(request, urlRequest: response.request, response: response.response, data: response.data, error: response.error)
    }
    public func request<Value: Sendable>(_ request: DataRequest, didParseResponse response: DataResponse<Value, AFError>) {
        capture(request, urlRequest: response.request, response: response.response, data: response.data, error: response.error)
    }
    private func isSupported(_ request: Request) -> Bool { request is DataRequest && !(request is UploadRequest) }
    private func capture(_ request: DataRequest, urlRequest: URLRequest?, response: HTTPURLResponse?, data: Data?, error: AFError?) {
        guard isSupported(request) else { return }
        if let urlRequest { store.captureRequest(id: request.id, request: urlRequest, isNewAttempt: false) }
        let diagnosis = Self.diagnose(error)
        store.finish(id: request.id, response: response, data: data, outcome: diagnosis.0, issue: diagnosis.1)
    }
    private static func diagnose(_ error: AFError?) -> (RequestOutcome, DiagnosticIssue?) {
        guard let error else { return (.success, nil) }
        if error.isExplicitlyCancelledError { return (.cancelled, .init(summary: TraceLocalization.text("Request cancelled by the caller"))) }
        if case let .responseSerializationFailed(reason) = error {
            if case let .decodingFailed(underlying) = reason, let decoding = underlying as? DecodingError {
                return (.decodingError, decodingIssue(decoding))
            }
            return (.decodingError, .init(summary: TraceLocalization.text("Response serialization failed. The raw error description is hidden because it may contain sensitive data.")))
        }
        if error.isResponseValidationError {
            return (.httpError, .init(summary: TraceLocalization.text("The response failed the configured status code or content type validation.")))
        }
        if let urlError = error.underlyingError as? URLError {
            let summary = switch urlError.code {
            case .timedOut: TraceLocalization.text("The request did not finish within the configured timeout.")
            case .notConnectedToInternet: TraceLocalization.text("The device is not connected to the internet.")
            case .cancelled: TraceLocalization.text("The underlying network task was cancelled.")
            default: TraceLocalization.format("Network task failed (URLError %@)", String(describing: urlError.code.rawValue))
            }
            return (urlError.code == .cancelled ? .cancelled : .networkError, .init(summary: summary))
        }
        return (.networkError, .init(summary: TraceLocalization.text("Request failed. The raw error description was not saved to avoid exposing the URL or body.")))
    }
    private static func decodingIssue(_ error: DecodingError) -> DiagnosticIssue {
        let context: DecodingError.Context
        let summary: String
        let expected: String?
        var missingKey: (any CodingKey)?
        switch error {
        case let .keyNotFound(key, value):
            context = value; missingKey = key; summary = TraceLocalization.text("JSON is missing a field required by the model."); expected = nil
        case let .valueNotFound(type, value):
            context = value; summary = TraceLocalization.text("A JSON field is null, but the model requires a non-null value."); expected = String(describing: type)
        case let .typeMismatch(type, value):
            context = value; summary = TraceLocalization.text("A JSON field type does not match the model."); expected = String(describing: type)
        case let .dataCorrupted(value):
            context = value; summary = TraceLocalization.text("The JSON format or field data could not be decoded."); expected = nil
        @unknown default:
            return .init(summary: TraceLocalization.text("JSON decoding failed"))
        }
        var path = ""
        var keys = context.codingPath
        if let missingKey { keys.append(missingKey) }
        for key in keys {
            if let index = key.intValue { path += "[\(index)]" }
            else { path += (path.isEmpty ? "" : ".") + key.stringValue }
        }
        return .init(summary: summary, fieldPath: String((path.isEmpty ? "$" : path).prefix(512)), expectedType: expected)
    }
}
