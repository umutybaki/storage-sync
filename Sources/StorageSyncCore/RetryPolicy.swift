import Foundation

public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: Duration
    public var maximumDelay: Duration
    /// `nil` keeps retrying transient failures indefinitely. Multi-day syncs must
    /// not become permanently failed merely because a network or drive stayed
    /// unavailable for a long time.
    public var maximumAttempts: Int?

    public init(
        baseDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(5 * 60),
        maximumAttempts: Int? = nil
    ) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
    }

    public func delay(forAttempt attempt: Int, randomUnit: Double) -> Duration? {
        guard attempt >= 0,
              maximumAttempts.map({ attempt < $0 }) ?? true else { return nil }
        let baseSeconds = durationSeconds(baseDelay)
        let maximumSeconds = durationSeconds(maximumDelay)
        let exponent = min(attempt, 62)
        let exponential = min(maximumSeconds, baseSeconds * pow(2, Double(exponent)))
        let jitter = max(0, min(1, randomUnit))
        return .milliseconds(Int64(exponential * jitter * 1_000))
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
