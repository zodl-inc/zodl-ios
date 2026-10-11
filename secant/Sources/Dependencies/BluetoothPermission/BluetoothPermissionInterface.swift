//
//  BluetoothPermissionInterface.swift
//  Zashi
//
//  MOB-2020: the Turn On and Unlock step (Figma 1599:11430) requests Bluetooth access before
//  pushing the device picker when it hasn't been asked yet, so the iOS system prompt appears over
//  that step instead of silently during the picker's first scan.
//

import ComposableArchitecture
import CoreBluetooth

extension DependencyValues {
    var bluetoothPermission: BluetoothPermissionClient {
        get { self[BluetoothPermissionClient.self] }
        set { self[BluetoothPermissionClient.self] = newValue }
    }
}

@DependencyClient
struct BluetoothPermissionClient {
    /// `CBManager.authorization` at this instant -- `.notDetermined` until the user has been asked.
    var authorizationStatus: @Sendable () -> CBManagerAuthorization = { .notDetermined }
    /// Creates a `CBCentralManager`, which shows the iOS Bluetooth permission prompt when
    /// authorization is `.notDetermined`, and returns once authorization has settled (at once when
    /// it was already determined). Doesn't report the outcome -- a denial still leaves the caller
    /// free to proceed, exactly as an already-determined `.denied` does.
    var requestAuthorization: @Sendable () async -> Void = { }
}
