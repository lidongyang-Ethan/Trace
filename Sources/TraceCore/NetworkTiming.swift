import Foundation

/// Durations in seconds for the last transaction of the current attempt.
/// Connection establishment includes TLS when applicable.
public struct NetworkTiming: Sendable, Encodable, Equatable {
    public let reusedConnection: Bool
    public let dns: TimeInterval?
    public let connection: TimeInterval?
    public let tls: TimeInterval?
    public let waitForFirstByte: TimeInterval?
    public let download: TimeInterval?

    public init(transaction: URLSessionTaskTransactionMetrics) {
        reusedConnection = transaction.isReusedConnection
        dns = Self.interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        connection = Self.interval(transaction.connectStartDate, transaction.connectEndDate)
        tls = Self.interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        waitForFirstByte = Self.interval(transaction.requestEndDate, transaction.responseStartDate)
        download = Self.interval(transaction.responseStartDate, transaction.responseEndDate)
    }

    private static func interval(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }
}
