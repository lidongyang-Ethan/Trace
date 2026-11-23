import Foundation

/// A point-in-time export of records already sanitized by DiagnosticsStore.
public struct RequestExport: Encodable, Sendable {
    public let schemaVersion = 1
    public let exportedAt: Date
    public let records: [RequestRecord]

    public init(records: [RequestRecord]) {
        self.records = records
        exportedAt = Date()
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
