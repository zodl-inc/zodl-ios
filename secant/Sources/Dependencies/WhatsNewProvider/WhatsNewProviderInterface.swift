//
//  WhatsNewProviderInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024.
//

import ComposableArchitecture

extension DependencyValues {
    var whatsNewProvider: WhatsNewProviderClient {
        get { self[WhatsNewProviderClient.self] }
        set { self[WhatsNewProviderClient.self] = newValue }
    }
}

struct WhatNewSection: Codable, Equatable {
    var title: String
    var bulletpoints: [String]
    
    static let zero = WhatNewSection(title: "", bulletpoints: [])

    init(title: String, bulletpoints: [String]) {
        self.title = title
        self.bulletpoints = bulletpoints
    }
}

struct WhatNewRelease: Codable, Equatable {
    var version: String
    var date: String
    var timestamp: Int
    var sections: [WhatNewSection]

    static let zero = WhatNewRelease(version: "", date: "", timestamp: 0, sections: [])

    init(version: String, date: String, timestamp: Int, sections: [WhatNewSection]) {
        self.version = version
        self.date = date
        self.timestamp = timestamp
        self.sections = sections
    }
}

struct WhatNewReleases: Codable, Equatable {
    var releases: [WhatNewRelease]
    
    static let zero = WhatNewReleases(releases: [])
    
    init(releases: [WhatNewRelease]) {
        self.releases = releases
    }
}

@DependencyClient
struct WhatsNewProviderClient {
    var latest: @Sendable () -> WhatNewRelease = { WhatNewRelease(version: "", date: "", timestamp: 0, sections: []) }
    var all: @Sendable () -> WhatNewReleases = { WhatNewReleases(releases: [WhatNewRelease(version: "", date: "", timestamp: 0, sections: [])]) }
}
