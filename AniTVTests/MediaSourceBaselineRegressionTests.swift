//
//  MediaSourceBaselineRegressionTests.swift
//  AniTVTests
//

import Foundation
import XCTest
@testable import AniTV

final class FastTimeoutHTTPClient: HTTPClient {
    private let session: URLSession

    init(timeout: TimeInterval = 6.0) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            throw URLError(.init(rawValue: httpResponse.statusCode))
        }
        return data
    }
}

struct BaselineItem: Codable {
    let index: Int
    let name: String
    let matchedCount: Int
    let episodes: [String]
}

struct RegressionComparisonItem: Codable {
    let index: Int
    let name: String
    let baselineCount: Int
    let currentCount: Int
    let status: String
    let episodes: [String]
}

@MainActor
final class MediaSourceBaselineRegressionTests: XCTestCase {

    func testRegressionAgainstBaseline() async throws {
        NSLog("[REGRESSION] ==================== [REGRESSION TEST START] ====================")

        // 1. Load baseline from temporary cache if available, or fall back to known baseline expectations
        var baselineMap: [String: Int] = [
            "稀饭动漫": 5,
            "嘀嗒影视": 11,
            "叽哔动漫": 7,
            "海星动漫": 12,
            "樱花动漫": 6,
            "番茄动漫": 8,
            "wedm": 9,
            "影视森林": 6,
            "girigiri愛動漫": 0
        ]
        let baselinePath = "/tmp/anitv_baseline.json"
        if let baselineData = try? Data(contentsOf: URL(fileURLWithPath: baselinePath)),
           let baselineItems = try? JSONDecoder().decode([BaselineItem].self, from: baselineData) {
            for item in baselineItems {
                baselineMap[item.name] = item.matchedCount
            }
            NSLog("[REGRESSION] Loaded %d baseline items from %@", baselineItems.count, baselinePath)
        }

        // 2. Fetch new subscription (which parses root mediaSources with new configs)
        let response = try await MediaSourceConfigLoader.downloadResponse(from: MediaSourceConfigLoader.defaultSubscriptionURL)
        let sources = response.mediaSources
        NSLog("[REGRESSION] Loaded %d media sources from new configuration", sources.count)

        var comparisonList: [RegressionComparisonItem] = []
        let httpClient = FastTimeoutHTTPClient(timeout: 6.0)

        for (index, src) in sources.enumerated() {
            var arguments = src.arguments
            arguments.searchConfig.requestInterval = 0.1 // Fast test execution
            let name = arguments.name
            let config = MediaSourceConfig(serializedArguments: nil, arguments: arguments)
            let mediaSource = SelectorMediaSource(
                mediaSourceId: "\(index + 1)",
                config: config,
                repository: SelectorMediaSourceEpisodeCacheRepository(),
                client: httpClient
            )

            let request = MediaFetchRequest(
                subjectId: "400600",
                episodeId: "1",
                subjectNameCN: "葬送的芙莉莲",
                subjectNames: ["葬送的芙莉莲"],
                episodeSort: .normal(number: 1.0),
                episodeName: "冒险的结束",
                episodeEp: .normal(number: 1.0)
            )

            let fetchTask = Task { () -> [MediaMatch] in
                return await mediaSource.fetch(query: request)
            }

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                fetchTask.cancel()
            }

            let matches = await fetchTask.value
            timeoutTask.cancel()

            let matchedTitles = matches.map { "\($0.media.properties.subjectName) - \($0.media.properties.episodeName)" }
            let baselineMatches = baselineMap[name] ?? 0
            let status = (baselineMatches > 0 && matches.count == 0) ? "REGRESSION_FAIL" : "PASS"

            let comp = RegressionComparisonItem(
                index: index + 1,
                name: name,
                baselineCount: baselineMatches,
                currentCount: matches.count,
                status: status,
                episodes: matchedTitles
            )
            comparisonList.append(comp)

            NSLog("[REGRESSION] [%d/%d] %@: baseline=%d, new=%d (status=%@, sample=%@)",
                  index + 1, sources.count, name, baselineMatches, matches.count, status, matchedTitles.first ?? "None")
        }

        // Save comparison JSON to /tmp
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let compData = try encoder.encode(comparisonList)
        try compData.write(to: URL(fileURLWithPath: "/tmp/anitv_regression_result.json"))

        // Assert 1: No regressions for existing sources that had matches in baseline
        for comp in comparisonList {
            if comp.baselineCount > 0 {
                XCTAssertGreaterThan(comp.currentCount, 0,
                                     "Regression detected! Source '\(comp.name)' had \(comp.baselineCount) matches in baseline but 0 in new engine!")
            }
        }

        // Assert 2: Girigiri must now have matches > 0!
        guard let girigiriResult = comparisonList.first(where: { $0.name.lowercased().contains("girigiri") }) else {
            XCTFail("girigiri source not found in new configuration")
            return
        }

        NSLog("[REGRESSION] Girigiri match count: baseline=%d, new=%d",
              girigiriResult.baselineCount, girigiriResult.currentCount)
        XCTAssertEqual(girigiriResult.baselineCount, 0, "Girigiri should have had 0 matches in baseline")
        XCTAssertGreaterThan(girigiriResult.currentCount, 0, "Girigiri MUST have matches > 0 under the new engine!")
        NSLog("[REGRESSION] ==================== [REGRESSION TEST PASSED SUCCESSFULLY] ====================")
    }
}
