//
//  DecodeResult.swift
//
//
//  Created by LiYan on 6/1/23.
//

import Foundation
import URKit

public struct DecodeResult : Equatable {
    internal init(progress: Int, ur: UR? = nil) {
        self.progress = progress
        self.ur = ur
    }

    public var progress: Int
    public var ur: UR?
}
