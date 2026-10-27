// IStopController.swift
// Attempts to turn i-stop (idling stop) off automatically at the start of each drive by replaying an
// experimental CAN frame learned by IStopFinder. The physical OFF switch is a resistor ladder read
// by the instrument cluster; replaying a related frame may not reproduce a real press. i-stop is Mazda's
// engine stop-at-idle; the car has a physical OFF button for it, and this does the same thing so
// you don't have to press it every time you get in.
//
//   OBDAdapter.isReady (engine ECU answering) ──▶ wait out of the battery-reset window, then make a
//   low-rate, one-off RPM safety check until the engine is running ──▶ if i-stop is on, send one short frame
//   sequence (OBDAdapter.injectFrame) ──▶ re-read the state to confirm. Once per OBD session.
//
// Why a finder and not a fixed command: nothing about i-stop is a standard OBD2 PID, and this car
// (2015 CX-5 2.2D) wasn't measured up front, so the state flag and a frame candidate are learned on
// the car first (IStopFinder), exactly like the M flag and the turn-signal frame.
//
// Caveats (see README): adapter acceptance does not mean the PCM accepted the frame. The cluster's
// CAN message may contain a rolling counter/checksum; if so, replaying captured bytes is not enough.

import Combine
import Foundation

private typealias Tuning = AppConfig.IStop

final class IStopController: ObservableObject {

    /// A short line for the dashboard.
    @Published private(set) var status = "i-stop: off-at-start not set up yet"
    /// What the last press did ("pressed, i-stop now off"), for the dashboard.
    @Published private(set) var lastAction: String?
    /// True while a press is in progress.
    @Published private(set) var busy = false

    /// Results for the dashboard log.
    var onLog: ((String) -> Void)?

    /// The learned OFF-button frame (set by IStopFinder); nil = can't press yet.
    var buttonFrame: FrameSignal? {
        didSet { updateStatus() }
    }

    private let obd: OBDAdapter
    private var subscriptions = Set<AnyCancellable>()
    /// Tracks an attempted action for this OBD session. After any ambiguous send we must not send a
    /// second toggle blindly, since the first one may have reached the PCM.
    private var attemptedThisDrive = false
    private var armTask: Task<Void, Never>?

    init(obd: OBDAdapter) {
        self.obd = obd
        updateStatus()
    }

    /// Starts watching for the start of a drive. Call from AppModel.start().
    func start() {
        guard Tuning.enabled else { return }
        obd.$isReady
            .removeDuplicates()
            .sink { [weak self] ready in self?.readyChanged(ready) }
            .store(in: &subscriptions)
    }

    /// The dashboard's test button: press OFF now, whatever the state.
    func test() {
        Task { await press(reason: "test") }
    }

    // MARK: Per-drive auto-off

    private func readyChanged(_ ready: Bool) {
        armTask?.cancel()
        armTask = nil
        guard ready else {
            attemptedThisDrive = false      // the car went away: the next connection is a new drive
            updateStatus()
            return
        }
        armTask = Task { [weak self] in await self?.armAndPress() }
    }

    /// Waits out of the battery-management reset window and until the engine is really running, then
    /// turns i-stop off once.
    private func armAndPress() async {
        try? await Task.sleep(for: Tuning.pressDelay)
        for _ in 0..<Tuning.armAttempts {
            if Task.isCancelled || !obd.isReady { return }
            if await obd.isEngineRunningForIStop() {
                await autoOff()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func autoOff() async {
        guard Tuning.enabled, !attemptedThisDrive, obd.isReady else { return }
        if Tuning.requireStateKnown, obd.iStopOff == nil {
            for _ in 0..<Tuning.stateWaitAttempts {
                try? await Task.sleep(for: Tuning.stateWaitInterval)
                guard obd.isReady else { return }
                if obd.iStopOff != nil { break }
            }
        }
        if obd.iStopOff == true {
            attemptedThisDrive = true
            log("already off at the start of the drive, nothing to do")
            return
        }
        if obd.iStopOff == nil, Tuning.requireStateKnown {
            log("i-stop state not learned yet — skipping auto-off (run the i-stop finder)")
            return
        }
        attemptedThisDrive = true
        await press(reason: "start of drive")
    }

    // MARK: Press

    /// Sends one short simulated OFF press and checks the state afterwards.
    func press(reason: String) async {
        guard let frame = buttonFrame else {
            log("can't press: the OFF-button frame isn't learned yet (open the i-stop finder)")
            return
        }
        guard obd.isReady, !busy else { return }
        busy = true
        defer { busy = false }
        status = "i-stop: pressing OFF (\(reason))…"
        let sent = await obd.runBetweenRounds { adapter in
            await adapter.injectFrame(id: frame.id, bytes: frame.pressed,
                                      count: Tuning.pressFrameCount, interval: Tuning.pressFrameInterval)
        }
        guard sent == true else {
            log("press didn't go out (adapter busy or disconnected)")
            return
        }
        log("adapter accepted OFF-frame replay (\(frame.label())); checking…")
        try? await Task.sleep(for: Tuning.confirmDelay)
        switch obd.iStopOff {
        case true?:
            lastAction = "pressed → i-stop off"
            log("confirmed: i-stop is now off")
        case false?:
            lastAction = "pressed → still on"
            log("pressed but i-stop is still on — this car may not accept a replayed button (see README)")
        case nil:
            lastAction = "pressed (can't confirm)"
            log("pressed; the i-stop state isn't learned, so this can't be confirmed")
        }
        updateStatus()
    }

    // MARK: Helpers

    private func log(_ message: String) {
        onLog?("i-stop: " + message)
        status = "i-stop: " + message
    }

    private func updateStatus() {
        guard Tuning.enabled else { status = "i-stop: off"; return }
        if buttonFrame == nil {
            status = "i-stop: OFF button not learned — open the i-stop finder"
        } else if let action = lastAction {
            status = "i-stop: \(action)"
        } else {
            status = "i-stop: will switch off at the start of each drive"
        }
    }
}
