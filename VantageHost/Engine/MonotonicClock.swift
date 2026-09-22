import Foundation

/// Host monotonic clock in nanoseconds, shared by capture timestamps and stats.
nonisolated enum MonotonicClock {
    static func nanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
