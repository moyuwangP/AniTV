//
//  AniTVApp.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/2/10.
//

import SwiftUI
import SwiftData
import SQLiteData
import AVFoundation

@main
struct AniTVApp: App {
    let appDatabase: DatabaseQueue
    @StateObject private var bangumiOAuthManager = BangumiOAuthManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[AniTVApp] Failed to configure playback AVAudioSession: \(error)")
        }

        do {
            let database = try AniTVDatabase.makeDefaultDatabase()
            self.appDatabase = database

            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil &&
               ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil &&
               NSClassFromString("XCTestCase") == nil {
                prepareDependencies {
                    $0.defaultDatabase = database
                }
            }
        } catch {
            fatalError("Could not create database: \(error)")
        }
    }

    var body: some Scene {

        WindowGroup {
            if NSClassFromString("XCTestCase") != nil {
                Color.clear
            } else {
                AppBootstrapView(database: appDatabase)
                    .environmentObject(bangumiOAuthManager)
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
