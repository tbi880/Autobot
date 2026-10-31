// ReconnectTimer.swift
// Bluetooth reconnection shared by both devices (LampController, OBDAdapter). A disconnect already
// starts a new scan straight away; this covers the attempts that hang — the device isn't found, a
// connection never completes, or its services never get set up. While a device isn't connected,
// the attempt is dropped and started again once a minute (AppConfig.Bluetooth.reconnectInterval).

import CoreBluetooth

/// Calls `retry` when a connection attempt hasn't succeeded in time: arm() at every attempt (when
/// scanning starts), disarm() once the device is usable or Bluetooth is off. Every retry starts a
/// new attempt, which arms the timer again, so a lost device is retried once a minute until it's back.
final class ReconnectTimer {
    private let retry: () -> Void
    private var countdown: Task<Void, Never>?

    init(retry: @escaping () -> Void) {
        self.retry = retry
    }

    /// Starts the countdown again from the full interval.
    func arm() {
        countdown?.cancel()
        countdown = Task { [weak self] in
            try? await Task.sleep(for: AppConfig.Bluetooth.reconnectInterval)
            guard !Task.isCancelled else { return }
            self?.retry()
        }
    }

    func disarm() {
        countdown?.cancel()
        countdown = nil
    }
}

extension CBCentralManager {
    /// Drops the connection attempt in progress so a new one can start: stops scanning and cancels
    /// the connection to `peripheral`, whether it's still pending or connected but never set up.
    func cancelAttempt(on peripheral: CBPeripheral?) {
        stopScan()
        if let peripheral, peripheral.state != .disconnected {
            cancelPeripheralConnection(peripheral)
        }
    }
}
