//
//  TMDBRepository.swift
//  AniTV
//
//  Created by Feiran Yang on 2026/4/5.
//

import Foundation
import SQLiteData

private enum TMDBConfig {
    static let baseURL = "https://api.themoviedb.org/3"
    static let imageBaseURL = "https://image.tmdb.org/t/p/original"
    static let cacheMaxAge: TimeInterval = 7 * 24 * 60 * 60
}

private struct TMDBImagesResponse: Decodable {
    let backdrops: [TMDBImage]
}

private struct TMDBImage: Decodable {
    let filePath: String
    let width: Int
    let voteAverage: Double
    let iso6391: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case width
        case voteAverage = "vote_average"
        case iso6391 = "iso_639_1"
    }
}

struct TMDBRepository {
    @Dependency(\.defaultDatabase) private var database

    // 通过 Bangumi Subject ID 优先从 bangumi-tmdb-map 获取背景图
    func getBackdrop(subjectId: Int) async -> String {
        if let entry = await TmdbSubjectMapManager.shared.lookup(subjectId: subjectId),
           let path = entry.backdropPath, !path.isEmpty {
            return TMDBConfig.imageBaseURL + path
        }

        // 回退尝试查 bangumi_data
        if let tmdbID = try? await AniTVDatabase.tmdbIDForBangumiID(String(subjectId), in: database) {
            return await getBackdrop(tmdbID: tmdbID)
        }
        return ""
    }

    // tmdbID example: "movie/12345" or "tv/12345"
    func getBackdrop(tmdbID: String) async -> String {
        let normalizedTMDBID = normalizeTMDBID(tmdbID)

        do {
            if let cached = try await AniTVDatabase.cachedTMDBBackdropURL(
                tmdbID: normalizedTMDBID,
                maxAge: TMDBConfig.cacheMaxAge,
                in: database
            ) {
                return cached
            }
        } catch {
            print("[TMDBRepository] Cache read error: \(error)")
        }

        let apiKey = AppConfig.tmdbAPIKey
        guard !apiKey.isEmpty else {
            print("[TMDBRepository] Missing TMDBApiKey in Info.plist")
            return ""
        }

        guard let url = URL(string: "\(TMDBConfig.baseURL)/\(normalizedTMDBID)/images?api_key=\(apiKey)") else {
            return ""
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return ""
            }

            let payload = try JSONDecoder().decode(TMDBImagesResponse.self, from: data)
            let candidates = payload.backdrops.filter { $0.width >= 1920 }
            let pool = candidates.isEmpty ? payload.backdrops : candidates
            guard !pool.isEmpty else { return "" }

            let sorted = pool.sorted { lhs, rhs in
                let lhsWeight = languageWeight(lhs.iso6391)
                let rhsWeight = languageWeight(rhs.iso6391)
                if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
                return lhs.voteAverage > rhs.voteAverage
            }

            let finalURL = TMDBConfig.imageBaseURL + sorted[0].filePath

            do {
                try await AniTVDatabase.upsertTMDBBackdropCache(
                    tmdbID: normalizedTMDBID,
                    imageURL: finalURL,
                    in: database
                )
            } catch {
                print("[TMDBRepository] Cache write error: \(error)")
            }

            return finalURL
        } catch {
            print("[TMDBRepository] Request/decode error: \(error)")
            return ""
        }
    }

    private func languageWeight(_ value: String?) -> Int {
        guard let value else { return 4 } // null/empty is second priority
        let normalized = value.lowercased()
        if normalized.isEmpty || normalized == "null" { return 4 }
        if normalized == "ja" { return 3 }
        if normalized == "zh" || normalized == "cn" || normalized == "zh-cn" { return 2 }
        if normalized == "en" { return 1 }
        return 0
    }

    private func normalizeTMDBID(_ tmdbID: String) -> String {
        let components = tmdbID
            .split(separator: "/")
            .map(String.init)

        guard components.count >= 2 else { return tmdbID }
        return "\(components[0])/\(components[1])"
    }
}
