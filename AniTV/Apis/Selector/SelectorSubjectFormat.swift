
import Foundation
import SwiftSoup

// Make Configs conform to SelectorFormatConfig and provide isValid implementations
extension SelectorSubjectFormatAConfig: SelectorFormatConfig {
    func isValid() -> Bool {
        return !selectLists.isEmpty
    }
}

extension SelectorSubjectFormatIndexedConfig: SelectorFormatConfig {
    func isValid() -> Bool {
        return !selectNames.isEmpty && !selectLinks.isEmpty
    }
}

extension SelectorSubjectFormatJsonPathIndexedPathConfig: SelectorFormatConfig {
    func isValid() -> Bool {
        return !selectLinks.isEmpty && !selectNames.isEmpty
    }
}

// Using 'class' for SelectorSubjectFormat implementations to match Kotlin's sealed class behavior more closely,
// and allow them to be passed as objects if needed.
// 'AnyObject' constraint on protocol indicates that only class types can conform to it.
protocol SelectorSubjectFormat: AnyObject {
    var id: SelectorFormatId { get }
    func select(document: HTMLDocument, baseUrl: String, config: SelectorFormatConfig) -> [WebSearchSubjectInfo]?
}

// Implementation of SelectorSubjectFormatA
class SelectorSubjectFormatA: SelectorSubjectFormat {
    let id: SelectorFormatId = SelectorFormatId("a")

    func select(document: HTMLDocument, baseUrl: String, config: SelectorFormatConfig) -> [WebSearchSubjectInfo]? {
        guard let config = config as? SelectorSubjectFormatAConfig, config.isValid() else { return nil }
        
        guard let cssSelector = config.selectLists.toCSSSelectorOrNil() else { return nil }
        let elements:Elements
        do{
            elements = try document.select(cssSelector: cssSelector)
        
            let subjects = try elements.compactMap { a -> WebSearchSubjectInfo? in
                let name = try a.attr("title").isEmpty ? a.text() : a.attr("title")
                let href = try a.attr("href")
                
                guard !name.isEmpty, !href.isEmpty else { return nil }

                let id = SelectorHelpers.guessIdFromUrl(href: href)
                return WebSearchSubjectInfo(
                    internalId: id,
                    name: name,
                    fullUrl: SelectorHelpers.computeAbsoluteUrl(baseUrl: baseUrl, relativeUrl: href),
                    partialUrl: href,
                    origin: a // HTMLElement is a struct, so it's copied
                )
            }
            
            if config.preferShorterName {
                return subjects.sorted { $0.name.count < $1.name.count }
            } else {
                return subjects
            }
        }catch{
            return nil
        }
    }
}

// Implementation of SelectorSubjectFormatIndexed
class SelectorSubjectFormatIndexed: SelectorSubjectFormat {
    let id: SelectorFormatId = SelectorFormatId("indexed")

    func select(document: HTMLDocument, baseUrl: String, config: SelectorFormatConfig) -> [WebSearchSubjectInfo]? {
        guard let config = config as? SelectorSubjectFormatIndexedConfig, config.isValid() else { return nil }

        guard let nameSelector = config.selectNames.toCSSSelectorOrNil(),
              let linkSelector = config.selectLinks.toCSSSelectorOrNil() else { return nil }

        let nameElements: Elements
        let linkElements: Elements
        
        do{
            nameElements = try document.select(cssSelector: nameSelector)
            linkElements = try document.select(cssSelector: linkSelector)


            let names: [String] = try nameElements.compactMap {
                let text = try $0.text().trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            let links: [String] = try linkElements.compactMap {
                let href = try $0.attr("href")
                return href.isEmpty ? nil : href
            }

            var subjects: [WebSearchSubjectInfo] = []
            for i in 0..<min(names.count, links.count) {
                let name = names[i]
                let href = links[i]
                
                let id = SelectorHelpers.guessIdFromUrl(href: href)
                subjects.append(WebSearchSubjectInfo(
                    internalId: id,
                    name: name,
                    fullUrl: SelectorHelpers.computeAbsoluteUrl(baseUrl: baseUrl, relativeUrl: href),
                    partialUrl: href,
                    origin: nil // No direct origin element for indexed approach
                ))
            }

            if config.preferShorterName {
                return subjects.sorted { $0.name.count < $1.name.count }
            } else {
                return subjects
            }
        }catch{
            return nil
        }
    }
}

// Implementation of SelectorSubjectFormatJsonPathIndexed
class SelectorSubjectFormatJsonPathIndexed: SelectorSubjectFormat {
    let id: SelectorFormatId = SelectorFormatId("json-path-indexed")

    func select(document: HTMLDocument, baseUrl: String, config: SelectorFormatConfig) -> [WebSearchSubjectInfo]? {
        guard let config = config as? SelectorSubjectFormatJsonPathIndexedPathConfig, config.isValid() else { return nil }

        let names = JSONPathEvaluator.evaluateToStrings(jsonString: document.content, path: config.selectNames)
        let rawLinks = JSONPathEvaluator.evaluateToStrings(jsonString: document.content, path: config.selectLinks)

        guard !names.isEmpty, !rawLinks.isEmpty else {
            return nil
        }

        var subjects: [WebSearchSubjectInfo] = []
        let count = min(names.count, rawLinks.count)

        for i in 0..<count {
            let name = names[i].trimmingCharacters(in: .whitespacesAndNewlines)
            var href = rawLinks[i].trimmingCharacters(in: .whitespacesAndNewlines)

            if let template = config.linkTemplate, !template.isEmpty {
                href = template
                    .replacingOccurrences(of: "{value}", with: href)
                    .replacingOccurrences(of: "{id}", with: href)
                    .replacingOccurrences(of: "{link}", with: href)
            }

            let id = SelectorHelpers.guessIdFromUrl(href: href)
            let fullUrl = SelectorHelpers.computeAbsoluteUrl(baseUrl: baseUrl, relativeUrl: href)

            subjects.append(WebSearchSubjectInfo(
                internalId: id,
                name: name,
                fullUrl: fullUrl,
                partialUrl: href,
                origin: nil
            ))
        }

        if config.preferShorterName {
            return subjects.sorted { $0.name.count < $1.name.count }
        } else {
            return subjects
        }
    }
}
