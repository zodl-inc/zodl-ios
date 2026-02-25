//
//  SupportDataGenerator.swift
//  secant
//
//  Created by Michal Fousek on 28.02.2023.
//

import AVFoundation
import Foundation
import LocalAuthentication
import UIKit
import Generated
import Utils

public struct SupportData: Equatable {
    public let toAddress: String
    public let subject: String
    public var message: String
}

public enum SupportDataGenerator {
    public enum Constants {
        public static let email = "support@zodl.com"
        public static let subject = L10n.Accounts.zashi
        public static let subjectPPE = L10n.ProposalPartial.mailSubject
    }
    
    public static func generate(_ prefix: String? = nil) -> SupportData {
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

    public static func generateOSStatusError(osStatus: OSStatus) -> SupportData {
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
        static let timeKey = L10n.SupportData.TimeItem.time
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
        static let bundleIdentifierKey = L10n.SupportData.AppVersionItem.bundleIdentifier
        static let versionKey = L10n.SupportData.AppVersionItem.version
        static let unknownVersion = L10n.General.unknown
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
        static let systemVersionKey = L10n.SupportData.SystemVersionItem.version
    }

    func generate() -> [(String, String)] {
        return [(Constants.systemVersionKey, UIDevice.current.systemVersion)]
    }
}

private struct DeviceModelItem: SupportDataGeneratorItem {
    private enum Constants {
        static let deviceModelKey = L10n.SupportData.DeviceModelItem.device
        static let unknownDevice = L10n.General.unknown
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
        static let localeKey = L10n.SupportData.LocaleItem.locale
        static let groupingSeparatorKey = L10n.SupportData.LocaleItem.groupingSeparator
        static let decimalSeparatorKey = L10n.SupportData.LocaleItem.decimalSeparator
        static let unknownSeparator = L10n.General.unknown
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
        static let freeDiskSpaceKey = L10n.SupportData.FreeDiskSpaceItem.freeDiskSpace
        static let freeDiskSpaceUnknown = L10n.General.unknown
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
        static let permissionsKey = L10n.SupportData.PermissionItem.permissions
        static let cameraPermKey = L10n.SupportData.PermissionItem.camera
        static let faceIDAvailable = L10n.SupportData.PermissionItem.faceID
        static let touchIDAvailable = L10n.SupportData.PermissionItem.touchID
        static let yesText = L10n.General.yes
        static let noText = L10n.General.no
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
