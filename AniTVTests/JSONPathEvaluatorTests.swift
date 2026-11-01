//
//  JSONPathEvaluatorTests.swift
//  AniTVTests
//

import XCTest
@testable import AniTV

final class JSONPathEvaluatorTests: XCTestCase {

    func testGirigiriApiResponseEvaluation() throws {
        let json = """
        {
          "code": 1,
          "msg": "获取成功",
          "info": {
            "offset": 0,
            "limit": 24,
            "total": 2,
            "rows": [
              {
                "vod_id": 26879,
                "vod_name": "葬送的芙莉莲 第二季"
              },
              {
                "vod_id": 25524,
                "vod_name": "葬送的芙莉莲"
              }
            ]
          }
        }
        """

        let ids = JSONPathEvaluator.evaluateToStrings(jsonString: json, path: "$.info.rows[*].vod_id")
        let names = JSONPathEvaluator.evaluateToStrings(jsonString: json, path: "$.info.rows[*].vod_name")

        XCTAssertEqual(ids, ["26879", "25524"])
        XCTAssertEqual(names, ["葬送的芙莉莲 第二季", "葬送的芙莉莲"])
    }

    func testBracketMultiKeyAndFallback() throws {
        let json = """
        [
          {"url": "https://example.com/a", "title": "Title A"},
          {"link": "https://example.com/b", "name": "Title B"}
        ]
        """

        let links = JSONPathEvaluator.evaluateToStrings(jsonString: json, path: "$[*]['url', 'link']")
        let titles = JSONPathEvaluator.evaluateToStrings(jsonString: json, path: "$[*]['title','name']")

        XCTAssertEqual(links, ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(titles, ["Title A", "Title B"])
    }

    func testSelectorSubjectFormatJsonPathIndexedWithLinkTemplate() throws {
        let json = """
        {
          "info": {
            "rows": [
              { "vod_id": 25524, "vod_name": "葬送的芙莉莲" }
            ]
          }
        }
        """

        var config = SelectorSubjectFormatJsonPathIndexedPathConfig()
        config.selectLinks = "$.info.rows[*].vod_id"
        config.selectNames = "$.info.rows[*].vod_name"
        config.linkTemplate = "/GV{value}/"

        let format = SelectorSubjectFormatJsonPathIndexed()
        let subjects = format.select(
            document: HTMLDocument(content: json),
            baseUrl: "https://bg.girigirilove.com",
            config: config
        )

        XCTAssertNotNil(subjects)
        XCTAssertEqual(subjects?.count, 1)
        XCTAssertEqual(subjects?.first?.name, "葬送的芙莉莲")
        XCTAssertEqual(subjects?.first?.partialUrl, "/GV25524/")
        XCTAssertEqual(subjects?.first?.fullUrl, "https://bg.girigirilove.com/GV25524/")
    }
}
