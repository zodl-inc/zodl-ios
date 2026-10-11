//
//  BluetoothPermissionLiveKey.swift
//  Zashi
//

import ComposableArchitecture
import CoreBluetooth

extension BluetoothPermissionClient: DependencyKey {
    static let liveValue = Self(
        authorizationStatus: { CBManager.authorization },
        requestAuthorization: {
            await BluetoothPermissionRequester().request()
        }
    )
}

/// Bridges `CBCentralManagerDelegate`'s callback-based API to `async/await`. Creating the manager
/// is what shows the iOS permission prompt when authorization is `.notDetermined`; the delegate
/// can report `centralManagerDidUpdateState` once before the user has actually answered that
/// prompt (still `.notDetermined`), so only a callback landing AFTER authorization has actually
/// settled resumes the continuation. `@unchecked Sendable`: `manager`/`continuation` are only ever
/// touched from `request()`'s continuation body and this delegate callback, never concurrently.
private final class BluetoothPermissionRequester: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<Void, Never>?

    func request() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // No power alert here -- this manager exists only to ask for Bluetooth access, not to
            // nag about Bluetooth being off (the device picker's own scan reports that separately).
            manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        continuation?.resume()
        continuation = nil
    }
}
