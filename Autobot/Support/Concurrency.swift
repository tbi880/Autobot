// Concurrency.swift
// Small helpers for code that receives callbacks on background threads
// (audio taps, speech recognition, speech rendering).

import Foundation

/// Runs `work` on the main thread, in the order calls were made. Safe to call from any thread.
nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { work() }
    }
}

/// Runs `operation`, returning nil if it throws or takes longer than `seconds`.
nonisolated func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
