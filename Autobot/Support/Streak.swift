// Streak.swift
// "The same reading several times in a row": how ReverseLight, ManualShiftDetector, SpeedMonitor and
// RainMode make sure of a value from the car before they act on it.

/// Counts how many readings in a row had the same value.
nonisolated struct Streak<Value: Equatable> {
    /// The value of the latest readings; nil before the first one and after reset().
    private(set) var value: Value?
    /// How many readings in a row have had `value`.
    private(set) var count = 0

    /// Takes the next reading and returns how many in a row have now had its value (1: it just changed).
    @discardableResult
    mutating func record(_ reading: Value) -> Int {
        if reading == value {
            count += 1
        } else {
            value = reading
            count = 1
        }
        return count
    }

    /// Forgets the readings so far.
    mutating func reset() {
        value = nil
        count = 0
    }
}
