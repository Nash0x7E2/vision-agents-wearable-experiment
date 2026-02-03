//
//  rayban_agentsApp.swift
//  rayban_agents
//
//  Created by Neevash Ramdial on 2/1/26.
//

import SwiftUI
import StreamVideo

@main
struct rayban_agentsApp: App {
    init() {
        LogConfig.level = .debug
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
