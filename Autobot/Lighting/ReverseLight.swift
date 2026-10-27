// ReverseLight.swift
// Yellow gradient breathing while the lever is in R (reversing). Out of R, the request is withdrawn and
// the lamp goes back to what Power Mode shows: purple steady in P / N / D, red breathing in M.
//
// The lever comes from the car: the TCM's gear value, read every round of live data (7E1 221E12:
// 3C in R, 46 in P, 32 in N, the gear in D / M; MazdaTCM, OBDSample.selector). A reading counts once
// it has held for AppConfig.Reverse.confirmReadings readings; a round without the TCM's answer changes
// nothing, and no live data at all means "not in R". The dashboard's R button stands in for the lever
// (tap = in R, tap again = back to the car's lever) until the car's lever changes.
//
// The breathing is a LightingArbiter request from `.reverse`, on Power Mode's level (R and M never
// meet): Power Mode's switch flash, the A/C flash, the turn signals / hazard lights and the door alert
// all go above it, and it comes back when they end (hazard lights on while reversing: the current
// Power Mode colour flashes, then yellow breathing resumes).

import Combine
import Foundation

final class ReverseLight: ObservableObject {

    /// True while the lamp breathes yellow: the lever in R (the car's, or a test's).
    @Published private(set) var isOn = false
    /// True while the test button is in charge.
    @Published private(set) var simulated = false
    /// The car's lever is in R (confirmed); false also while unknown.
    @Published private(set) var carInReverse = false

    /// Changes, for the dashboard log.
    var onLog: ((String) -> Void)?

    private let lighting: LightingArbiter
    private var candidate: Bool?                 // in R or not, in the latest readings…
    private var candidateCount = 0               // …and in how many in a row
    private var subscription: AnyCancellable?

    init(obd: OBDAdapter, lighting: LightingArbiter) {
        self.lighting = lighting
        subscription = obd.$sample.sink { [weak self] sample in self?.handle(sample) }
    }

    /// Debug: as if the lever went into R; the same button again hands back to the car's lever.
    func simulate() {
        simulated.toggle()
        onLog?("Reverse test: " + (simulated ? "lever in R" : "back to the car's lever"))
        update()
    }

    // MARK: Private

    private func handle(_ sample: OBDSample?) {
        guard let sample else {                  // no live data: not in R, as far as anyone knows
            candidate = nil
            candidateCount = 0
            carChanged(to: false)
            return
        }
        guard let lever = sample.selector else { return }        // this round without the TCM: no news
        if case .unknown = lever { return }                      // unrecognised code: no news
        let inReverse = lever == .reverse
        if inReverse == candidate {
            candidateCount += 1
        } else {
            candidate = inReverse
            candidateCount = 1
        }
        guard candidateCount >= max(AppConfig.Reverse.confirmReadings, 1) else { return }
        carChanged(to: inReverse)
    }

    /// The car's lever went into R or out of it; that takes over from a test.
    private func carChanged(to inReverse: Bool) {
        guard inReverse != carInReverse else { return }
        carInReverse = inReverse
        simulated = false
        onLog?("Reverse: " + (inReverse ? "lever in R" : "out of R"))
        update()
    }

    private func update() {
        let on = AppConfig.Reverse.enabled && (simulated || carInReverse)
        guard on != isOn else { return }
        isOn = on
        if on {
            lighting.request(.yellowBreathing, from: .reverse)
        } else {
            lighting.clear(.reverse)                 // back to Power Mode (or whatever is above it)
        }
    }
}
