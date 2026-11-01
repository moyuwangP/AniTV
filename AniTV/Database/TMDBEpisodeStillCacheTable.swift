//
//  AniTVDatabase+TMDBEpisodeStillCache.swift
//  AniTV
//
//  Created by Codex on 2026/11/1.
//

import Foundation
import GRDB
import SQLiteData

struct EpisodeStillRecord: Sendable {
    let subjectId: Int
    let episodeId: Int
    let episodeSort: Double
    let stillPath: String?
    let airDate: String?
    let lastCheckedAt: Int
}

extension AniTVDatabase {
    static func registerTMDBEpisodeStillCacheMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("Create tmdb_episode_still_cache table") { db in
            try #sql(
                """
                CREATE TABLE "tmdb_episode_still_cache" (
                  "subject_id" INTEGER NOT NULL,
                  "episode_id" INTEGER NOT NULL,
                  "episode_sort" REAL NOT NULL,
                  "still_path" TEXT,
                  "air_date" TEXT,
                  "last_checked_at" INTEGER NOT NULL,
                  PRIMARY KEY ("subject_id", "episode_id")
                ) STRICT
                """
            )
            .execute(db)

            try #sql(
                """
                CREATE INDEX IF NOT EXISTS "index_tmdb_episode_still_cache_subject"
                ON "tmdb_episode_still_cache" ("subject_id")
                """
            )
            .execute(db)
        }
    }

    static func fetchCachedEpisodeStills(
        for subjectId: Int,
        in database: any DatabaseWriter
    ) async throws -> [Int: EpisodeStillRecord] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT "subject_id", "episode_id", "episode_sort", "still_path", "air_date", "last_checked_at"
                FROM "tmdb_episode_still_cache"
                WHERE "subject_id" = ?
                """,
                arguments: [subjectId]
            )
            var map: [Int: EpisodeStillRecord] = [:]
            for row in rows {
                let episodeId: Int = row["episode_id"]
                map[episodeId] = EpisodeStillRecord(
                    subjectId: row["subject_id"],
                    episodeId: episodeId,
                    episodeSort: row["episode_sort"],
                    stillPath: row["still_path"],
                    airDate: row["air_date"],
                    lastCheckedAt: row["last_checked_at"]
                )
            }
            return map
        }
    }

    static func upsertEpisodeStills(
        _ records: [EpisodeStillRecord],
        in database: any DatabaseWriter
    ) async throws {
        guard !records.isEmpty else { return }
        try await database.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO "tmdb_episode_still_cache" (
                      "subject_id",
                      "episode_id",
                      "episode_sort",
                      "still_path",
                      "air_date",
                      "last_checked_at"
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT("subject_id", "episode_id") DO UPDATE SET
                      "still_path" = excluded."still_path",
                      "air_date" = excluded."air_date",
                      "last_checked_at" = excluded."last_checked_at"
                    """,
                    arguments: [
                        record.subjectId,
                        record.episodeId,
                        record.episodeSort,
                        record.stillPath,
                        record.airDate,
                        record.lastCheckedAt
                    ]
                )
            }
        }
    }
}
