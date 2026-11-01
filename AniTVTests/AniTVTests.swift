//
//  AniTVTests.swift
//  AniTVTests
//
//  Created by Feiran Yang on 2026/2/10.
//

import Foundation
import XCTest
@testable import AniTV

final class AniTVTests: XCTestCase {

    func testExample() async throws {
        // Write your test here
    }

    func testTimelineServiceDemo() async throws {
        let database = try AniTVDatabase.makeDefaultDatabase()

        if try await AniTVDatabase.isBangumiDataEmpty(in: database) {
            let release = try await AniTVDatabase.resolveBangumiDataRelease()
            let items = try await AniTVDatabase.downloadBangumiData(from: release.url)
            try await AniTVDatabase.replaceBangumiData(items, version: release.version, in: database)
        }

        let service = TimelineService()
        let timeline = try await service.fetchTimelineMap(
            database: database,
            now: Date(),
            daysBefore: 7,
            daysAfter: 7
        )

        let sortedKeys = timeline.keys.sorted()
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm:ss"

        var orderedEntries: [[String: Any]] = []
        for key in sortedKeys {
            let entries = timeline[key, default: []]
            for entry in entries {
                let formattedTime: String
                if entry.airingTimestamp == .max {
                    formattedTime = "unknown"
                } else {
                    let date = Date(timeIntervalSince1970: TimeInterval(entry.airingTimestamp))
                    formattedTime = timeFormatter.string(from: date)
                }

                orderedEntries.append([
                    "date": key,
                    "time": formattedTime,
                    "airingTimestamp": entry.airingTimestamp,
                    "subjectTitle": entry.subjectTitle,
                    "subjectTitleCN": entry.subjectTitleCN as Any,
                    "episodeSort": entry.episodeSort as Any,
                    "episodeName": entry.episodeName as Any,
                    "episodeNameCN": entry.episodeNameCN as Any,
                    "bangumiID": entry.bangumiID as Any,
                    "anilistID": entry.anilistID as Any,
                    "isAniListMissing": entry.isAniListMissing,
                    "coverImageURL": entry.coverImageURL as Any
                ])
            }
        }

        let payload: [String: Any] = [
            "dayCount": timeline.count,
            "days": sortedKeys,
            "entries": orderedEntries
        ]

        let jsonData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }

        XCTAssertFalse(timeline.isEmpty)
    }

    func testHlsManifestFilterAdDetection() throws {
        // Build simulated low-density playlist with sandwiched ad
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:5",
            "#EXT-X-MEDIA-SEQUENCE:0"
        ]
        
        // Group 0: 30 segments of 3s = 90s
        for i in 0..<30 {
            lines.append("#EXTINF:3.000000,")
            lines.append("main_seg_\(i).ts")
        }
        
        // Group 1 (Ad): 5 segments of 4s = 20s
        lines.append("#EXT-X-DISCONTINUITY")
        for i in 0..<5 {
            lines.append("#EXTINF:4.000000,")
            lines.append("ad_seg_\(i).ts")
        }
        
        // Group 2: 30 segments of 3s = 90s
        lines.append("#EXT-X-DISCONTINUITY")
        for i in 30..<60 {
            lines.append("#EXTINF:3.000000,")
            lines.append("main_seg_\(i).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        
        let content = lines.joined(separator: "\n")
        let result = HlsManifestFilter.filter(content: content)
        
        XCTAssertEqual(result.status, .filtered)
        XCTAssertEqual(result.removedGroups.count, 1)
        XCTAssertEqual(result.removedGroups.first?.segmentCount, 5)
        XCTAssertFalse(result.content.contains("ad_seg_"))
        XCTAssertTrue(result.content.contains("main_seg_0.ts"))
        XCTAssertTrue(result.content.contains("main_seg_59.ts"))
    }

    func testHlsManifestFilterMasterPlaylistUnsupported() throws {
        let masterContent = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000,RESOLUTION=1080x608
        2000k/hls/index.m3u8
        """
        let result = HlsManifestFilter.filter(content: masterContent)
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.reason, "master_playlist")
    }

    func testHlsManifestFilterLivePlaylistUnsupported() throws {
        let liveContent = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:4.0,
        seg2.ts
        """
        let result = HlsManifestFilter.filter(content: liveContent)
        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.reason, "live_or_incomplete_playlist")
    }

    func testHlsManifestFilterImplicitIvUnchanged() throws {
        let content = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:100.0,
        main1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:10.0,
        ad1.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:100.0,
        main2.ts
        #EXT-X-ENDLIST
        """
        let result = HlsManifestFilter.filter(content: content)
        XCTAssertEqual(result.status, .unchanged)
        XCTAssertEqual(result.reason, "encrypted_implicit_iv")
    }

    func testRememberDanmakuStateLogic() async throws {
        // 1. When remember is true, resolve follows lastDanmakuEnabled
        AniTVDatabase.persistDanmakuStateIfRememberEnabled(false, in: nil)
        UserDefaults.standard.set(true, forKey: AniTVDatabase.rememberDanmakuStateSettingKey)
        XCTAssertFalse(AniTVDatabase.resolvedInitialDanmakuEnabled())

        AniTVDatabase.persistDanmakuStateIfRememberEnabled(true, in: nil)
        XCTAssertTrue(AniTVDatabase.resolvedInitialDanmakuEnabled())

        // 2. When remember is false, resolve is always true regardless of last saved state
        AniTVDatabase.persistDanmakuStateIfRememberEnabled(false, in: nil)
        UserDefaults.standard.set(false, forKey: AniTVDatabase.rememberDanmakuStateSettingKey)
        XCTAssertTrue(AniTVDatabase.resolvedInitialDanmakuEnabled())

        // Reset to default
        UserDefaults.standard.set(true, forKey: AniTVDatabase.rememberDanmakuStateSettingKey)
        UserDefaults.standard.set(true, forKey: AniTVDatabase.lastDanmakuEnabledSettingKey)
    }
}
