//
//  SupportDataGenerator.swift
//  secant
//
//  Created by Michal Fousek on 28.02.2023.
//

@preconcurrency import AVFoundation
import Foundation
import LocalAuthentication
import UIKit

struct SupportData: Equatable {
    let toAddress: String
    let subject: String
    var message: String
}

enum SupportDataGenerator {
    enum Constants {
        static let email = "support@zodl.com"
        static let subject = String(localizable: .accountsZashi)
        static let subjectPPE = String(localizable: .proposalPartialMailSubject)
    }
    
    static func generate(_ prefix: String? = nil) -> SupportData {
        let items: [SupportDataGeneratorItem] = [
            TimeItem(),
            AppVersionItem(),
            SystemVersionItem(),
            DeviceModelItem(),
            LocaleItem(),
            FreeDiskSpaceItem(),
            PermissionsItems()
        ]

        let message = items
            .map { $0.generate() }
            .flatMap { $0 }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")

        if let prefix {
            let finalMessage = "\(prefix)\n\(message)"
            
            return SupportData(toAddress: Constants.email, subject: Constants.subject, message: finalMessage)
        } else {
            return SupportData(toAddress: Constants.email, subject: Constants.subject, message: message)
        }
    }

    static func generateOSStatusError(osStatus: OSStatus) -> SupportData {
        let data = SupportDataGenerator.generate()
        
        let message =
        """
        OSStatus: \(osStatus)
        \(data.message)
        """
        
        return SupportData(toAddress: Constants.email, subject: Constants.subjectPPE, message: message)
    }
}

private protocol SupportDataGeneratorItem {
    func generate() -> [(String, String)]
}

private struct TimeItem: SupportDataGeneratorItem {
    private enum Constants {
        static let timeKey = String(localizable: .supportDataTimeItemTime)
    }

    let dateFormatter: DateFormatter

    init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd hh:mm:ss a ZZZZ"
        dateFormatter.locale = Locale(identifier: "en_US")
    }

    func generate() -> [(String, String)] {
        return [(Constants.timeKey, dateFormatter.string(from: Date()))]
    }
}

private struct AppVersionItem: SupportDataGeneratorItem {
    private enum Constants {
        static let bundleIdentifierKey = String(localizable: .supportDataAppVersionItemBundleIdentifier)
        static let versionKey = String(localizable: .supportDataAppVersionItemVersion)
        static let unknownVersion = String(localizable: .generalUnknown)
    }

    func generate() -> [(String, String)] {
        let bundle = Bundle.main
        guard let infoDict = bundle.infoDictionary else { return [(Constants.versionKey, Constants.unknownVersion)] }

        var data: [(String, String)] = []
        if let bundleIdentifier = bundle.bundleIdentifier {
            data.append((Constants.bundleIdentifierKey, bundleIdentifier))
        }

        if let build = infoDict["CFBundleVersion"] as? String, let version = infoDict["CFBundleShortVersionString"] as? String {
            data.append((Constants.versionKey, "\(version) (\(build))"))
        } else {
            data.append((Constants.versionKey, Constants.unknownVersion))
        }

        return data
    }
}

private struct SystemVersionItem: SupportDataGeneratorItem {
    private enum Constants {
        static let systemVersionKey = String(localizable: .supportDataSystemVersionItemVersion)
    }

    func generate() -> [(String, String)] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [(Constants.systemVersionKey, "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")]
    }
}

private struct DeviceModelItem: SupportDataGeneratorItem {
    private enum Constants {
        static let deviceModelKey = String(localizable: .supportDataDeviceModelItemDevice)
        static let unknownDevice = String(localizable: .generalUnknown)
    }

    func generate() -> [(String, String)] {
        var systemInfo = utsname()
        uname(&systemInfo)
        var readModel: String?
        withUnsafePointer(to: &systemInfo.machine.0) { charPointer in
            readModel = String(cString: charPointer, encoding: .ascii)
        }

        let model = readModel ?? Constants.unknownDevice
        return [(Constants.deviceModelKey, model)]
    }
}

private struct LocaleItem: SupportDataGeneratorItem {
    private enum Constants {
        static let localeKey = String(localizable: .supportDataLocaleItemLocale)
        static let groupingSeparatorKey = String(localizable: .supportDataLocaleItemGroupingSeparator)
        static let decimalSeparatorKey = String(localizable: .supportDataLocaleItemDecimalSeparator)
        static let unknownSeparator = String(localizable: .generalUnknown)
    }

    func generate() -> [(String, String)] {
        let locale = Locale.current

        return [
            (Constants.localeKey, locale.identifier),
            (Constants.groupingSeparatorKey, "'\(locale.groupingSeparator ?? Constants.unknownSeparator)'"),
            (Constants.decimalSeparatorKey, "'\(locale.decimalSeparator ?? Constants.unknownSeparator)'")
        ]
    }
}

private struct FreeDiskSpaceItem: SupportDataGeneratorItem {
    private enum Constants {
        static let freeDiskSpaceKey = String(localizable: .supportDataFreeDiskSpaceItemFreeDiskSpace)
        static let freeDiskSpaceUnknown = String(localizable: .generalUnknown)
    }

    func generate() -> [(String, String)] {
        let freeDiskSpace: String

        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let freeSpace = values.volumeAvailableCapacityForImportantUsage {
                freeDiskSpace = "\(freeSpace / 1024 / 1024) MB"
            } else {
                freeDiskSpace = Constants.freeDiskSpaceUnknown
            }
        } catch {
            LoggerProxy.debug("Can't get free disk space: \(error)")
            freeDiskSpace = Constants.freeDiskSpaceUnknown
        }

        return [(Constants.freeDiskSpaceKey, freeDiskSpace)]
    }
}

private struct PermissionsItems: SupportDataGeneratorItem {
    private enum Constants {
        static let permissionsKey = String(localizable: .supportDataPermissionItemPermissions)
        static let cameraPermKey = String(localizable: .supportDataPermissionItemCamera)
        static let faceIDAvailable = String(localizable: .supportDataPermissionItemFaceID)
        static let touchIDAvailable = String(localizable: .supportDataPermissionItemTouchID)
        static let yesText = String(localizable: .generalYes)
        static let noText = String(localizable: .generalNo)
    }

    func generate() -> [(String, String)] {
        let cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

        let bioAuthContext = LAContext()
        let biometricAuthAvailable = bioAuthContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        return [
            (Constants.permissionsKey, ""),
            (Constants.cameraPermKey, cameraAuthorized ? Constants.yesText : Constants.noText),
            (Constants.faceIDAvailable, biometricAuthAvailable && bioAuthContext.biometryType == .faceID ? Constants.yesText : Constants.noText),
            (Constants.touchIDAvailable, biometricAuthAvailable && bioAuthContext.biometryType == .touchID ? Constants.yesText : Constants.noText)
        ]
    }
}
