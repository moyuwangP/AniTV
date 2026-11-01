//
//  TmdbEpisodeMapResolver.swift
//  AniTV
//
//  Created by Codex on 2026/11/1.
//

import Foundation

/// 对应表里「每一集对应 TMDB 第几季第几集」的编码解析器 (参考 bangumi-tmdb-map)
///
/// 格式示例：
/// - `S3E1`: 本篇按集号从小到大, 第 k 集对第 3 季第 1+k 集
/// - `1-12:S3E1` 或 `7:S3E8`: 本篇集号范围
/// - `SP1-2:S0E5` 或 `SP12.1:S0E7`: 其他类型 (SP/OP/ED/PV/MAD/O)
struct TmdbEpisodeMapResolver: Sendable {
    struct Target: Equatable, Sendable {
        let season: Int
        let episode: Int
    }

    private let mainContinuation: (season: Int, firstEpisode: Int)?
    private let explicit: [String: Target] // "typePrefix:sortText" -> Target

    var seasons: Set<Int> {
        var set = Set<Int>()
        if let mainContinuation {
            set.insert(mainContinuation.season)
        }
        for target in explicit.values {
            set.insert(target.season)
        }
        return set
    }

    nonisolated static func parse(_ spec: String) -> TmdbEpisodeMapResolver? {
        let tokens = spec.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        var continuation: (season: Int, firstEpisode: Int)? = nil
        var explicit: [String: Target] = [:]

        let continuationRegex = try! NSRegularExpression(pattern: #"^S(\d+)E(\d+)$"#)
        let segmentRegex = try! NSRegularExpression(pattern: #"^([A-Z]*)(\d+(?:\.\d+)?)(?:-(\d+))?:S(\d+)E(\d+)$"#)
        let validPrefixes: Set<String> = ["", "SP", "OP", "ED", "PV", "MAD", "O"]

        for token in tokens {
            let nsToken = token as NSString
            let tokenRange = NSRange(location: 0, length: nsToken.length)

            if let cMatch = continuationRegex.firstMatch(in: token, options: [], range: tokenRange) {
                if continuation != nil { return nil }
                let sStr = nsToken.substring(with: cMatch.range(at: 1))
                let eStr = nsToken.substring(with: cMatch.range(at: 2))
                guard let s = Int(sStr), let e = Int(eStr) else { return nil }
                continuation = (s, e)
                continue
            }

            if let sMatch = segmentRegex.firstMatch(in: token, options: [], range: tokenRange) {
                let prefix = nsToken.substring(with: sMatch.range(at: 1))
                guard validPrefixes.contains(prefix) else { return nil }

                let fromStr = nsToken.substring(with: sMatch.range(at: 2))
                let toRange = sMatch.range(at: 3)
                let seasonStr = nsToken.substring(with: sMatch.range(at: 4))
                let epStr = nsToken.substring(with: sMatch.range(at: 5))

                guard let season = Int(seasonStr), let firstEp = Int(epStr) else { return nil }

                if toRange.location == NSNotFound {
                    let key = "\(prefix):\(fromStr)"
                    explicit[key] = Target(season: season, episode: firstEp)
                } else {
                    let toStr = nsToken.substring(with: toRange)
                    guard let start = Int(fromStr), let end = Int(toStr), end >= start else { return nil }
                    for offset in 0...(end - start) {
                        let curSort = start + offset
                        let key = "\(prefix):\(curSort)"
                        explicit[key] = Target(season: season, episode: firstEp + offset)
                    }
                }
            } else {
                return nil
            }
        }

        if continuation == nil && explicit.isEmpty {
            return nil
        }
        return TmdbEpisodeMapResolver(mainContinuation: continuation, explicit: explicit)
    }

    /// 将传入的 Bangumi 分集列表对齐到 TMDB 的 (Season, Episode)
    /// 返回值：[BgmEpisode.id: Target]
    func resolve(episodes: [BgmEpisodeInfo]) -> [Int: Target] {
        var result: [Int: Target] = [:]

        // 1. 如果有接续规则 S(x)E(y)，将所有正片 (type == 0) 按 sort 排序逐一递增对位
        if let (season, firstEp) = mainContinuation {
            let mainStories = episodes
                .filter { $0.type == 0 }
                .sorted { $0.sort < $1.sort }

            for (index, ep) in mainStories.enumerated() {
                result[ep.id] = Target(season: season, episode: firstEp + index)
            }
        }

        // 2. 显式覆盖（针对特定集号、SP、特别篇或分段）
        for ep in episodes {
            let prefix = typePrefix(ep.type)
            let sortStr = formatSort(ep.sort)
            let key = "\(prefix):\(sortStr)"
            if let target = explicit[key] {
                result[ep.id] = target
            }
        }

        return result
    }

    private func formatSort(_ sort: Double) -> String {
        if floor(sort) == sort {
            return String(Int(sort))
        }
        return String(sort)
    }

    private func typePrefix(_ type: Int) -> String {
        switch type {
        case 0: return ""
        case 1: return "SP"
        case 2: return "OP"
        case 3: return "ED"
        case 4: return "PV"
        case 5: return "MAD"
        default: return "O"
        }
    }
}
