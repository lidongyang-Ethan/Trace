import Foundation

/// Only structured JSON bodies are retained in v0.1. Free text is deliberately omitted.
public struct Redactor: Sendable {
    private let sensitive: Set<String>
    private let hidden = TraceLocalization.text("[REDACTED]")
    public init(configuration: DiagnosticsConfiguration) {
        sensitive = Set(configuration.sensitiveKeys.map { $0.lowercased() })
            .union(["authorization", "proxy-authorization", "cookie", "set-cookie"])
    }
    public func headers(_ headers: [String: String]) -> [String: String] {
        headers.mapValuesWithKeys { key, value in sensitive.contains(key.lowercased()) ? hidden : String(value.prefix(2_048)) }
    }
    public func url(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return TraceLocalization.text("Unknown URL") }
        if parts.user != nil { parts.user = hidden }
        if parts.password != nil { parts.password = hidden }
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.map { item in
            URLQueryItem(name: item.name, value: sensitive.contains(item.name.lowercased()) ? hidden : item.value)
        }
        return String((parts.string ?? TraceLocalization.text("Unknown URL")).prefix(8_192))
    }
    public func body(_ data: Data?, contentType: String?, configuration: DiagnosticsConfiguration) -> CapturedBody {
        guard configuration.capturesBodies else { return .init(state: .disabled) }
        guard let data, !data.isEmpty else { return .init(state: .absent) }
        let count = data.count
        guard count <= configuration.maximumBodyBytes,
              contentType?.lowercased().contains("json") == true,
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let safeData = try? JSONSerialization.data(withJSONObject: sanitize(object), options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]),
              safeData.count <= configuration.maximumBodyBytes,
              let text = String(data: safeData, encoding: .utf8)
        else { return .init(state: .omitted, originalByteCount: count) }
        return .init(state: .json, text: text, originalByteCount: count)
    }
    private func sanitize(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValuesWithKeys { key, value -> Any in
                sensitive.contains(key.lowercased()) ? hidden : sanitize(value)
            }
        }
        if let array = object as? [Any] { return array.map(sanitize) }
        return object
    }
}

private extension Dictionary where Key == String {
    func mapValuesWithKeys<T>(_ transform: (String, Value) -> T) -> [String: T] {
        Dictionary<String, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
