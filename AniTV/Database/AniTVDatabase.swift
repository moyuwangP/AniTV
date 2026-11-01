//
//  AniTVDatabase.swift
//  AniTV
//
//  Created by Codex on 2026/4/5.
//

import Foundation
import GRDB

enum AniTVDatabase {
    static func makeDefaultDatabase() throws -> DatabaseQueue {
        let databaseURL = try databaseURL()
        let database = try DatabaseQueue(path: databaseURL.path)

        var migrator = DatabaseMigrator()
        registerSystemSettingsMigrations(in: &migrator)
        registerMediaSourceMigrations(in: &migrator)
        registerBangumiDataMigrations(in: &migrator)
        registerTMDBBackdropCacheMigrations(in: &migrator)
        registerTimelineBangumiSubjectCacheMigrations(in: &migrator)
        registerTimelineBangumiEpisodeCacheMigrations(in: &migrator)
        registerTimelineMapCacheMigrations(in: &migrator)
        registerUserProfilesMigrations(in: &migrator)
        registerLocalEpisodeWatchStateMigrations(in: &migrator)
        registerCachedUserCollectionsMigrations(in: &migrator)
        registerTMDBEpisodeStillCacheMigrations(in: &migrator)
        try migrator.migrate(database)
        return database
    }

    private static func databaseURL() throws -> URL {
        let fileManager = FileManager.default
        let libraryURL = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let preferredDirectory = libraryURL
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AniTV", isDirectory: true)

        do {
            try fileManager.createDirectory(at: preferredDirectory, withIntermediateDirectories: true)
            return preferredDirectory.appendingPathComponent("AniTV.sqlite")
        } catch {
            let cachesURL = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let fallbackDirectory = cachesURL.appendingPathComponent("AniTV", isDirectory: true)
            try fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
            return fallbackDirectory.appendingPathComponent("AniTV.sqlite")
        }
    }
}
