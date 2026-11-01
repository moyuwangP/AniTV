//
//  TmdbSubjectMapManager.swift
//  AniTV
//
//  Created by Codex on 2026/11/1.
//

import Foundation

struct TmdbTitleLogo: Sendable, Equatable {
    let filePath: String
    let aspectRatio: Double
}

struct TmdbSubjectMapLogos: Sendable {
    let originalLanguage: String?
    let logos: [String: TmdbTitleLogo] // language -> TmdbTitleLogo (e.g. "zh", "ja", "en")

    static func parse(_ text: String?) -> TmdbSubjectMapLogos? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        var original: String? = nil
        var logos: [String: TmdbTitleLogo] = [:]

        for part in text.split(separator: " ") {
            let sub = part.split(separator: "=", maxSplits: 1)
            guard sub.count == 2 else { continue }
            let key = String(sub[0])
            let value = String(sub[1])

            if key == "o" {
                original = value
                continue
            }
            if value == "-" {
                continue
            }
            let logoParts = value.split(separator: ":", maxSplits: 1)
            if logoParts.count == 2, let aspect = Double(logoParts[1]) {
                logos[key] = TmdbTitleLogo(filePath: String(logoParts[0]), aspectRatio: aspect)
            } else if logoParts.count == 1 {
                logos[key] = TmdbTitleLogo(filePath: String(logoParts[0]), aspectRatio: 1.0)
            }
        }

        if original == nil && logos.isEmpty { return nil }
        return TmdbSubjectMapLogos(originalLanguage: original, logos: logos)
    }
}

struct TmdbSubjectMapEntry: Sendable {
    let bgmId: Int
    let backdropRef: String?     // e.g. "tv/209867" or "movie/23150"
    let backdropPath: String?    // e.g. "/rBOnrVlck7BIlGeWVlzYiZeg4l2.jpg"
    let stillsSource: String?    // e.g. "tv/209867", "tv/209867/season/0"
    let episodesRule: String?    // e.g. "S1E1", "1-12:S1E1 13-24:S2E1"
    let tmdbSeriesId: Int?       // 解析出纯数字 ID (若为 tv/123 -> 123)
    let logos: TmdbSubjectMapLogos?
}

actor TmdbSubjectMapManager {
    static let shared = TmdbSubjectMapManager()

    private var entries: [Int: TmdbSubjectMapEntry] = [:]
    private var isLoaded = false
    private var isLoading = false

    private let mapURLs = [
        "https://raw.githubusercontent.com/GrahamZen/bangumi-tmdb-map/main/map/bgm-tmdb.tsv",
        "https://fastly.jsdelivr.net/gh/GrahamZen/bangumi-tmdb-map@main/map/bgm-tmdb.tsv",
        "https://testingcf.jsdelivr.net/gh/GrahamZen/bangumi-tmdb-map@main/map/bgm-tmdb.tsv"
    ]

    private init() {}

    private var localFileURL: URL {
        let fileManager = FileManager.default
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cachesURL.appendingPathComponent("bangumi-tmdb-map", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bgm-tmdb.tsv")
    }

    private var metaFileURL: URL {
        localFileURL.deletingLastPathComponent().appendingPathComponent("meta.json")
    }

    struct CacheMeta: Codable {
        let lastCheckedAt: TimeInterval
        let etag: String?
    }

    func ensureLoaded() async {
        if isLoaded { return }
        if isLoading {
            while isLoading {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return
        }
        isLoading = true
        defer { isLoading = false }

        // 1. 尝试从本地缓存文件加载
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: localFileURL.path),
           let data = try? Data(contentsOf: localFileURL),
           !data.isEmpty {
            parseAndPopulate(from: data)
            isLoaded = true
        }

        // 2. 检查是否需要从远端刷新 (每 20 小时检查一次)
        let meta = loadMeta()
        let now = Date().timeIntervalSince1970
        if !isLoaded {
            // 本地无缓存，首次启动需同步等待下载完成
            await downloadAndRefresh(currentMeta: meta)
        } else if (now - meta.lastCheckedAt > 20 * 3600) {
            // 本地已有缓存，后台静默刷新
            Task.detached(priority: .utility) {
                await self.downloadAndRefresh(currentMeta: meta)
            }
        }
    }

    func lookup(subjectId: Int) async -> TmdbSubjectMapEntry? {
        await ensureLoaded()
        return entries[subjectId]
    }

    private func downloadAndRefresh(currentMeta: CacheMeta) async {
        for urlStr in mapURLs {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            if let etag = currentMeta.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { continue }

                if httpResponse.statusCode == 304 {
                    // 内容未修改，更新检查时间
                    saveMeta(CacheMeta(lastCheckedAt: Date().timeIntervalSince1970, etag: currentMeta.etag))
                    return
                }

                if httpResponse.statusCode == 200, !data.isEmpty {
                    // 校验是否为合法 TSV（以 # bangumi-tmdb-map 开头，使用纯字节前缀匹配避免 UTF-8 截断）
                    let expectedPrefix = Data("# bangumi-tmdb-map".utf8)
                    if data.starts(with: expectedPrefix) {
                        try? data.write(to: localFileURL, options: .atomic)
                        let newEtag = httpResponse.value(forHTTPHeaderField: "ETag")
                        saveMeta(CacheMeta(lastCheckedAt: Date().timeIntervalSince1970, etag: newEtag))
                        
                        parseAndPopulate(from: data)
                        isLoaded = true
                        print("[TmdbSubjectMapManager] Updated and loaded \(entries.count) entries from \(urlStr)")
                        return
                    }
                }
            } catch {
                print("[TmdbSubjectMapManager] Failed to fetch from \(urlStr): \(error)")
            }
        }
    }

    private func parseAndPopulate(from data: Data) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        var newEntries: [Int: TmdbSubjectMapEntry] = [:]

        content.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("#") { return }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let bgmId = Int(parts[0]) else { return }

            let backdropRef = parts[1].isEmpty ? nil : parts[1]
            let backdropPath = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let stillsSource = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
            let episodesRule = parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil
            let logosStr = parts.count > 6 && !parts[6].isEmpty ? parts[6] : nil
            let logos = TmdbSubjectMapLogos.parse(logosStr)

            var seriesId: Int? = nil
            if let target = stillsSource ?? backdropRef {
                let components = target.split(separator: "/")
                if components.count >= 2, let id = Int(components[1]) {
                    seriesId = id
                }
            }

            newEntries[bgmId] = TmdbSubjectMapEntry(
                bgmId: bgmId,
                backdropRef: backdropRef,
                backdropPath: backdropPath,
                stillsSource: stillsSource,
                episodesRule: episodesRule,
                tmdbSeriesId: seriesId,
                logos: logos
            )
        }

        self.entries = newEntries
    }

    private func loadMeta() -> CacheMeta {
        guard let data = try? Data(contentsOf: metaFileURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: data) else {
            return CacheMeta(lastCheckedAt: 0, etag: nil)
        }
        return meta
    }

    private func saveMeta(_ meta: CacheMeta) {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaFileURL, options: .atomic)
        }
    }
}
