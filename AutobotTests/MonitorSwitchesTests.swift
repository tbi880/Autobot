// MonitorSwitchesTests.swift
// The monitoring switches without a car: what a switch turns off, what a regeneration brings back, how the
// recorder's pace follows what is switched on, and that the switches are kept between launches.

import Foundation
import Testing
@testable import Autobot

@Suite struct MonitorSelectionTests {

    @Test func everythingIsOnToStartWith() {
        let selection = MonitorSelection()
        for field in DPFRecordPlan.fields {
            #expect(selection.monitors(did: field.did))
            #expect(selection.records(did: field.did, regenActive: false))
        }
        #expect(!selection.sweepOff)
        #expect(!DPFRecordPlan.regenOverrides(selection))
    }

    /// A group's switch turns off every value in it, and nothing else.
    @Test func groupSwitchTurnsItsValuesOff() {
        var selection = MonitorSelection()
        selection.set(.exhaustTemps, on: false)
        #expect(!selection.monitors(did: "F478"))
        #expect(!selection.records(did: "F478", regenActive: false))
        #expect(!selection.polls(did: "F478", regenActive: false))
        #expect(selection.monitors(did: "042D"))
        selection.set(.exhaustTemps, on: true)
        #expect(selection.polls(did: "F478", regenActive: false))
    }

    /// A value's own switch turns off just that value; it stays off when its group goes off and on again.
    @Test func valueSwitchTurnsOneValueOff() {
        var selection = MonitorSelection()
        selection.set(did: "F45C", on: false)
        #expect(!selection.polls(did: "F45C", regenActive: false))
        #expect(selection.polls(did: "0415", regenActive: false))      // same group (oil)
        selection.set(.oil, on: false)
        selection.set(.oil, on: true)
        #expect(!selection.monitors(did: "F45C"))
        #expect(selection.monitors(did: "0415"))
    }

    /// With their switch off the regeneration requests and count are still read (to notice a regeneration)
    /// but not recorded.
    @Test func regenerationIsNoticedWithItsSwitchOff() {
        var selection = MonitorSelection()
        selection.set(.soot, on: false)
        for did in ["0380", "0432"] {
            #expect(selection.polls(did: did, regenActive: false))
            #expect(!selection.records(did: did, regenActive: false))
        }
        #expect(!selection.polls(did: "042D", regenActive: false))
    }

    /// During a regeneration every value that has to do with one is read and recorded whatever the switches
    /// say; the others stay off; and the switches are as they were afterwards.
    @Test func regenerationOverridesTheSwitches() {
        var selection = MonitorSelection()
        for group in MonitorGroup.allCases { selection.set(group, on: false) }
        selection.set(did: "F47A", on: false)
        let before = selection
        #expect(DPFRecordPlan.regenOverrides(selection))

        for field in DPFRecordPlan.fields {
            let related = field.group?.regenRelated ?? false
            #expect(selection.records(did: field.did, regenActive: true) == related, "\(field.did)")
            #expect(selection.records(did: field.did, regenActive: false) == false, "\(field.did)")
        }
        #expect(selection.records(did: "F478", regenActive: true))      // exhaust temperatures
        #expect(selection.records(did: "042D", regenActive: true))      // PM_GEN
        #expect(!selection.records(did: "DD01", regenActive: true))     // odometer: nothing to do with it
        #expect(selection == before)
    }

    /// Every value read has a group (so a switch), once; and the CSV columns stay unique.
    @Test func everyValueHasASwitch() {
        let listed = MonitorGroup.dids.values.flatMap { $0 }
        #expect(Set(listed).count == listed.count)
        for field in DPFRecordPlan.fields {
            #expect(field.group != nil, "\(field.did) has no group")
        }
        let fieldDIDs = DPFRecordPlan.fields.map(\.did)
        #expect(Set(fieldDIDs).count == fieldDIDs.count)
        #expect(Set(listed) == Set(fieldDIDs))
        let columns = DPFRecordPlan.fields.flatMap(\.columns)
        #expect(Set(columns).count == columns.count)
        for did in MonitorGroup.sentinelDIDs {
            #expect(MonitorGroup.of(did: did)?.regenRelated == true)
        }
    }

    /// The columns recorded before 27 Nov 2026 keep their order; the new ones come after them.
    @Test func newColumnsComeLast() {
        let columns = DPFRecordPlan.fields.flatMap(\.columns)
        #expect(columns.first == "pm_gen")
        let firstNew = columns.firstIndex(of: "load_abs_pct")
        let lastOld = columns.firstIndex(of: "total_time")
        #expect(firstNew != nil && lastOld != nil)
        if let firstNew, let lastOld { #expect(firstNew == lastOld + 1) }
    }

    /// The new standard PIDs decode as SAE J1979 has them.
    @Test func newValuesDecode() {
        func decoded(_ did: String, _ bytes: [UInt8]) -> [Double?] {
            DPFRecordPlan.fieldByDID[did]?.decode(bytes) ?? []
        }
        #expect(decoded("F444", [0x80, 0x00]) == [1.0])                           // lambda 1
        #expect(decoded("F434", [0x80, 0x00, 0x80, 0x00]) == [1.0, 0.0])          // lambda 1, 0 mA
        #expect(decoded("F43C", [0x0B, 0x54]) == [250.0])                         // 2900/10 − 40
        #expect(decoded("F487", [0x01, 0x0C, 0x80]) == [100.0])                   // 3200/32 kPa
        #expect(decoded("F487", [0x00, 0x0C, 0x80]) == [nil])                     // not reported
        #expect(decoded("F465", [0x08, 0x08]) == [1.0])                           // glow plug lamp on
        #expect(decoded("F47F", [0x03, 0x00, 0x00, 0x0E, 0x10, 0x00, 0x00, 0x07, 0x08]) == [1.0, 0.5])
        #expect(DPFRecordPlan.fieldByDID["1674"]?.header == "7E1")
        #expect(DPFRecordPlan.fieldByDID["042D"]?.header == "7E0")
    }

    @Test func switchesAreKeptBetweenLaunches() throws {
        let suite = "monitor-switches-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = MonitorSwitches(defaults: defaults, key: "switches")
        #expect(first.selection == MonitorSelection())
        first.selection.set(.boost, on: false)
        first.selection.set(did: "F45E", on: false)
        first.selection.sweepOff = true

        let second = MonitorSwitches(defaults: defaults, key: "switches")
        #expect(!second.selection.isOn(.boost))
        #expect(!second.selection.monitors(did: "F45E"))
        #expect(second.selection.sweepOff)
        second.reset()
        #expect(MonitorSwitches(defaults: defaults, key: "switches").selection == MonitorSelection())
    }
}

@Suite struct PollPacerTests {

    private let limits = PollPacer.Limits(fast: 10, normal: 30, slow: 120, minFast: 3, maxFast: 60,
                                          maxStretch: 4, share: 0.5)

    private func costs(_ selection: MonitorSelection, regen: Bool = false) -> PollPacer.Costs {
        DPFRecordPlan.costs(selection, regenActive: regen, sweepReads: 10, perGo: 7)
    }

    /// Switching values off lowers what a sample costs; a regeneration puts the related ones back.
    @Test func costFollowsTheSwitches() {
        let all = costs(MonitorSelection())
        var selection = MonitorSelection()
        selection.set(.airEGR, on: false)
        selection.set(.fuel, on: false)
        selection.sweepOff = true
        let some = costs(selection)
        #expect(some.fast < all.fast)
        #expect(some.normal < all.normal)
        #expect(some.slow < all.slow)
        let inRegen = costs(selection, regen: true)
        #expect(inRegen.fast == all.fast)

        for group in MonitorGroup.allCases { selection.set(group, on: false) }
        let none = costs(selection)
        // Only the regeneration requests and count are left, with their share of the RPM reads.
        #expect(abs(none.fast - 2 * 7.0 / 6.0) < 0.0001)
        #expect(none.normal == 0 && none.slow == 0)
    }

    /// Fields that aren't read anyway (not supported, refused) don't count.
    @Test func unaskedValuesCostNothing() {
        let all = costs(MonitorSelection())
        let fewer = DPFRecordPlan.costs(MonitorSelection(), regenActive: false, sweepReads: 10, perGo: 7) {
            $0.did != "F478"
        }
        #expect(abs((all.fast - fewer.fast) - 3 * 7.0 / 6.0) < 0.0001)
    }

    /// More switched on than the link's share holds: every interval is stretched by the same factor.
    @Test func tooMuchStretchesTheIntervals() {
        let pacer = PollPacer(secondsPerRead: 0.25)
        // 40 reads every 10 s + 30 every 30 s + 24 every 120 s at 0.25 s each = 1.3 of the link.
        let plan = pacer.plan(PollPacer.Costs(fast: 40, normal: 30, slow: 24), limits: limits)
        #expect(abs(plan.demand - 1.3) < 0.0001)
        #expect(plan.fast == 26)
        #expect(plan.normal == 78)
        #expect(plan.slow == 312)
        // At the stretched intervals it fits the share.
        let used = 0.25 * (40 / plan.fast + 30 / plan.normal + 24 / plan.slow)
        #expect(used <= 0.5 + 0.0001)
    }

    /// Little switched on: samples come more often, the slower tiers keep their pace, never under the minimum.
    @Test func tooLittleShortensTheInterval() {
        let pacer = PollPacer(secondsPerRead: 0.25)
        let plan = pacer.plan(PollPacer.Costs(fast: 8, normal: 6, slow: 0), limits: limits)
        #expect(plan.fast == 5)                 // 2 s of reads in 0.45 of the link: 4.4 s, rounded up
        #expect(plan.normal == 30 && plan.slow == 120)
        let tiny = pacer.plan(PollPacer.Costs(fast: 2, normal: 0, slow: 0), limits: limits)
        #expect(tiny.fast == 3)
        let nothing = pacer.plan(PollPacer.Costs(), limits: limits)
        #expect(nothing.fast == 10)
    }

    /// The stretch has its limits: a sample at least every maxFast, the slower tiers at most maxStretch slower.
    @Test func stretchIsLimited() {
        let pacer = PollPacer(secondsPerRead: 1.0)
        let plan = pacer.plan(PollPacer.Costs(fast: 60, normal: 60, slow: 60), limits: limits)
        #expect(plan.fast == 60)
        #expect(plan.normal == 120)
        #expect(plan.slow == 480)
    }

    /// The pace follows the link: slower replies (heat, distance) stretch the intervals, faster ones give
    /// them back, and one odd measurement doesn't swing it.
    @Test func paceFollowsMeasuredRoundTrips() {
        var pacer = PollPacer(secondsPerRead: 0.25)
        let load = PollPacer.Costs(fast: 20, normal: 0, slow: 0)
        #expect(pacer.plan(load, limits: limits).fast == 10)
        #expect(!pacer.measured)

        pacer.observe(seconds: 4, reads: 40)                 // 0.1 s a read: the first measurement is taken as it is
        #expect(pacer.measured)
        #expect(abs(pacer.secondsPerRead - 0.1) < 0.0001)
        #expect(pacer.plan(load, limits: limits).fast == 4)

        for _ in 0..<30 { pacer.observe(seconds: 24, reads: 40) }      // the link slows to 0.6 s a read
        #expect(abs(pacer.secondsPerRead - 0.6) < 0.01)
        #expect(pacer.plan(load, limits: limits).fast == 24)

        let before = pacer.secondsPerRead
        pacer.observe(seconds: 400, reads: 40)               // one stuck sample: capped, and smoothed in
        #expect(pacer.secondsPerRead < before + 0.4)
        pacer.observe(seconds: 0, reads: 0)                  // nothing read: nothing learned
        #expect(pacer.secondsPerRead < before + 0.4)
    }

    /// Around a regeneration the override makes the sample bigger, and the pace makes room for it.
    @Test func regenerationLoadIsPaced() {
        var selection = MonitorSelection()
        for group in MonitorGroup.allCases { selection.set(group, on: false) }
        selection.sweepOff = true
        let pacer = PollPacer(secondsPerRead: 0.25)
        let regenLimits = PollPacer.Limits(fast: 5, normal: 30, slow: 120, minFast: 2, maxFast: 60,
                                           maxStretch: 4, share: 0.5)
        let quiet = pacer.plan(costs(selection), limits: limits)
        let regen = pacer.plan(costs(selection, regen: true), limits: regenLimits)
        #expect(quiet.fast == 3)
        #expect(regen.demand > quiet.demand)
        #expect(regen.fast > 5)                 // everything related is read: more than 5 s of the link's share
    }
}
