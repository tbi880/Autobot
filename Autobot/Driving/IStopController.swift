// IStopController.swift
// Turns i-stop (idling stop) off automatically at the start of each drive, by replaying the OFF
// button the start stop unit broadcasts on the bus (learned by IStopFinder). i-stop is Mazda's
// engine stop-at-idle; the car has a physical OFF button for it, and this does the same thing so
// you don't have to press it every time you get in.
//
//   OBDAdapter.isReady (engine ECU answering) ──▶ wait out of the battery-reset window, until the
//   engine is really running ──▶ if i-stop is on (the learned state signal), send ONE short OFF
//   press (OBDAdapter.injectFrame) ──▶ re-read the state to confirm. Once per drive.
//
// Why a finder and not a fixed command: nothing about i-stop is a standard OBD2 PID, and this car
// (2015 CX-5 2.2D) wasn't measured up front, so the state flag and the button frame are learned on
// the car first (IStopFinder), exactly like the M flag and the turn-signal frame.
//
// Caveats (see README): the start stop unit also broadcasts that frame ~10/s, so replaying it on the
// same id is best-effort — the PCM may ignore it. If it doesn't take, the log says so; the reliable
// permanent route is a one-off SSU coding change with FORScan.

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
    private var pressedThisDrive = false
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
            pressedThisDrive = false        // the car went away: the next connection is a new drive
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
            if let rpm = obd.rpm, rpm >= Tuning.minRunningRpm {
                await autoOff()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func autoOff() async {
        guard Tuning.enabled, !pressedThisDrive, obd.isReady else { return }
        if Tuning.requireStateKnown, obd.iStopOff == nil {
            try? await Task.sleep(for: .seconds(1))     // give the first state read a moment
            guard obd.isReady else { return }
        }
        if obd.iStopOff == true {
            pressedThisDrive = true
            log("already off at the start of the drive, nothing to do")
            return
        }
        if obd.iStopOff == nil, Tuning.requireStateKnown {
            log("i-stop state not learned yet — skipping auto-off (run the i-stop finder)")
            return
        }
        pressedThisDrive = true
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
        log("sent OFF press (\(frame.label())); checking…")
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
