//
//  TMDBEpisodeStillRepository.swift
//  AniTV
//
//  Created by Codex on 2026/11/1.
//

import Foundation
import SQLiteData

private struct TMDBSeasonDetailsResponse: Decodable {
    let seasonNumber: Int?
    let episodes: [TMDBSeasonEpisode]?

    enum CodingKeys: String, CodingKey {
        case seasonNumber = "season_number"
        case episodes
    }
}

private struct TMDBSeasonEpisode: Decodable {
    let episodeNumber: Int
    let stillPath: String?

    enum CodingKeys: String, CodingKey {
        case episodeNumber = "episode_number"
        case stillPath = "file_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodeNumber = try container.decode(Int.self, forKey: .episodeNumber)
        // still_path 在 season 接口中可能是 "still_path" 也可能是 "file_path"
        if let path = try? container.decodeIfPresent(String.self, forKey: .stillPath) {
            stillPath = path
        } else {
            let altContainer = try decoder.container(keyedBy: AltCodingKeys.self)
            stillPath = try? altContainer.decodeIfPresent(String.self, forKey: .stillPath)
        }
    }

    private enum AltCodingKeys: String, CodingKey {
        case stillPath = "still_path"
    }
}

actor TMDBEpisodeStillRepository {
    static let shared = TMDBEpisodeStillRepository()

    private let tmdbBaseURL = "https://api.themoviedb.org/3"
    private let tmdbImageBaseURL = "https://image.tmdb.org/t/p/w780" // 780 宽对于电视卡片清晰且适度

    // 进程内在途请求合流: subjectId -> Task
    private var inFlightTasks: [Int: Task<[Int: URL], Never>] = [:]

    private init() {}

    /// 获取某条目下所有分集的剧照 URL 字典 [episodeId: URL]
    func getEpisodeStills(
        subjectId: Int,
        episodes: [BgmEpisodeInfo],
        database: any DatabaseWriter
    ) async -> [Int: URL] {
        if let existing = inFlightTasks[subjectId] {
            return await existing.value
        }

        let task = Task<[Int: URL], Never> {
            await self.doGetEpisodeStills(subjectId: subjectId, episodes: episodes, database: database)
        }
        inFlightTasks[subjectId] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: subjectId)
        return result
    }

    private func doGetEpisodeStills(
        subjectId: Int,
        episodes: [BgmEpisodeInfo],
        database: any DatabaseWriter
    ) async -> [Int: URL] {
        let now = Int(Date().timeIntervalSince1970)
        let fourteenDaysSeconds = 14 * 24 * 3600
        let sixHoursSeconds = 6 * 3600

        // 1. 读取本地 SQLite 缓存
        var cachedMap: [Int: EpisodeStillRecord] = [:]
        do {
            cachedMap = try await AniTVDatabase.fetchCachedEpisodeStills(for: subjectId, in: database)
        } catch {
            print("[TMDBEpisodeStillRepository] Read cache error: \(error)")
        }

        // 2. 检查哪些集需要拉取 TMDB
        // 判定准则：
        // a) 如果已有 stillPath (非空) -> 永久有效，不需拉取
        // b) 如果 stillPath 为空：
        //    - 若 airDate 距今超过 14 天 -> 视为确认无图，永久有效，不需拉取
        //    - 若 airDate 距今未满 14 天 (或无 airDate) -> 距上次拉取不足 6 小时则跳过；已满 6 小时则需要拉取
        // c) 如果本地完全无该集记录 -> 需要拉取
        var needsRefresh = false
        var resultURLs: [Int: URL] = [:]

        for ep in episodes {
            if let record = cachedMap[ep.id] {
                if let path = record.stillPath, !path.isEmpty {
                    if let url = URL(string: tmdbImageBaseURL + path) {
                        resultURLs[ep.id] = url
                    }
                    continue
                }

                // 暂无图的记录
                let airDateTimestamp = parseAirDate(record.airDate ?? ep.airdate)
                let isOlderThan14Days: Bool
                if let airDateTimestamp {
                    isOlderThan14Days = (now - airDateTimestamp) > fourteenDaysSeconds
                } else {
                    isOlderThan14Days = false
                }

                if isOlderThan14Days {
                    // 超过 14 天确认无图，不再重发请求
                    continue
                }

                // 未超 14 天，看距离上次检查是否满 6 小时
                if (now - record.lastCheckedAt) >= sixHoursSeconds {
                    needsRefresh = true
                }
            } else {
                // 完全没有缓存过
                needsRefresh = true
            }
        }

        // 如果所有集都已满足缓存规则，直接返回
        if !needsRefresh && !cachedMap.isEmpty {
            return resultURLs
        }

        // 3. 需从 TMDB 查询：查找映射规则
        guard let mapEntry = await TmdbSubjectMapManager.shared.lookup(subjectId: subjectId) else {
            return resultURLs
        }

        guard let seriesId = mapEntry.tmdbSeriesId,
              let rule = mapEntry.episodesRule,
              let resolver = TmdbEpisodeMapResolver.parse(rule) else {
            return resultURLs
        }

        let resolvedTargets = resolver.resolve(episodes: episodes) // [episodeId: Target(season, ep)]
        let seasonsToFetch = resolver.seasons

        let apiKey = AppConfig.tmdbAPIKey
        guard !apiKey.isEmpty else { return resultURLs }

        // 4. 批量拉取涉及的每个 Season
        var seasonStillMap: [String: String] = [:] // "season:episode" -> still_path
        await withTaskGroup(of: (Int, [Int: String]?).self) { group in
            for season in seasonsToFetch {
                group.addTask {
                    let stills = await self.fetchSeasonStills(seriesId: seriesId, season: season, apiKey: apiKey)
                    return (season, stills)
                }
            }

            for await (season, stills) in group {
                guard let stills else { continue }
                for (epNum, path) in stills {
                    seasonStillMap["\(season):\(epNum)"] = path
                }
            }
        }

        // 5. 将拉取到的结果装配并更新到 SQLite
        var recordsToUpsert: [EpisodeStillRecord] = []
        for ep in episodes {
            let target = resolvedTargets[ep.id]
            let path: String?
            if let target {
                path = seasonStillMap["\(target.season):\(target.episode)"]
            } else {
                path = nil
            }

            let effectivePath = path ?? cachedMap[ep.id]?.stillPath
            if let effectivePath, !effectivePath.isEmpty {
                if let url = URL(string: tmdbImageBaseURL + effectivePath) {
                    resultURLs[ep.id] = url
                }
            }

            recordsToUpsert.append(
                EpisodeStillRecord(
                    subjectId: subjectId,
                    episodeId: ep.id,
                    episodeSort: ep.sort,
                    stillPath: effectivePath,
                    airDate: ep.airdate,
                    lastCheckedAt: now
                )
            )
        }

        do {
            try await AniTVDatabase.upsertEpisodeStills(recordsToUpsert, in: database)
        } catch {
            print("[TMDBEpisodeStillRepository] Upsert stills error: \(error)")
        }

        return resultURLs
    }

    private func fetchSeasonStills(seriesId: Int, season: Int, apiKey: String) async -> [Int: String]? {
        guard let url = URL(string: "\(tmdbBaseURL)/tv/\(seriesId)/season/\(season)?api_key=\(apiKey)&language=zh-CN") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let payload = try JSONDecoder().decode(TMDBSeasonDetailsResponse.self, from: data)
            guard let episodes = payload.episodes else { return [:] }

            var map: [Int: String] = [:]
            for item in episodes {
                if let path = item.stillPath, !path.isEmpty {
                    map[item.episodeNumber] = path
                }
            }
            return map
        } catch {
            print("[TMDBEpisodeStillRepository] Fetch season \(season) error: \(error)")
            return nil
        }
    }

    private func parseAirDate(_ str: String?) -> Int? {
        guard let str = str?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: str).map { Int($0.timeIntervalSince1970) }
    }
}
