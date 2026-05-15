//
//  AppDelegateAction.swift
//  Zashi
//
//  Created by Lukáš Korba on 27.03.2022.
//

import Foundation
import BackgroundTasks

enum AppDelegateAction: Equatable {
    case didFinishLaunching
    case didEnterBackground
    case willEnterForeground
    case backgroundTask(BGProcessingTask)
}
