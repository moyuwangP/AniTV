//
//  JSONPathEvaluator.swift
//  AniTV
//

import Foundation

enum JSONPathEvaluator {

    enum PathSegment: Equatable {
        case property(String)
        case index(Int)
        case wildcard
        case multiProperty([String])
        case recursiveDescent
    }

    /// Evaluates a JSONPath query against a JSON object (Dictionary, Array, etc.)
    /// and returns the matched string values.
    static func evaluateToStrings(json: Any, path: String) -> [String] {
        let results = evaluate(json: json, path: path)
        return results.compactMap { item -> String? in
            if let str = item as? String {
                return str
            } else if let num = item as? NSNumber {
                return num.stringValue
            } else if let bool = item as? Bool {
                return bool ? "true" : "false"
            }
            return nil
        }
    }

    /// Evaluates a JSONPath query against a JSON string.
    static func evaluateToStrings(jsonString: String, path: String) -> [String] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        return evaluateToStrings(json: json, path: path)
    }

    /// Evaluates a JSONPath query against a JSON object and returns the matched Any items.
    static func evaluate(json: Any, path: String) -> [Any] {
        let segments = parse(path: path)
        guard !segments.isEmpty else { return [json] }
        return evaluateSegments(current: [json], segments: segments[...])
    }

    /// Parse a JSONPath string into segments.
    static func parse(path: String) -> [PathSegment] {
        var str = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("$") {
            str.removeFirst()
        }

        var segments: [PathSegment] = []
        var index = str.startIndex

        while index < str.endIndex {
            let ch = str[index]

            if ch == "." {
                let nextIdx = str.index(after: index)
                if nextIdx < str.endIndex && str[nextIdx] == "." {
                    // ".." recursive descent
                    segments.append(.recursiveDescent)
                    index = str.index(after: nextIdx)
                    continue
                } else {
                    index = nextIdx
                    continue
                }
            } else if ch == "[" {
                // Find closing ']'
                guard let closeIdx = str[index...].firstIndex(of: "]") else {
                    break
                }
                let inner = String(str[str.index(after: index)..<closeIdx]).trimmingCharacters(in: .whitespaces)
                index = str.index(after: closeIdx)

                if inner == "*" {
                    segments.append(.wildcard)
                } else if let intVal = Int(inner) {
                    segments.append(.index(intVal))
                } else {
                    // Could be 'a', 'b' or "a", "b" or single 'a'
                    let keys = extractKeysFromBracket(inner)
                    if keys.count == 1 {
                        segments.append(.property(keys[0]))
                    } else if keys.count > 1 {
                        segments.append(.multiProperty(keys))
                    }
                }
            } else {
                // Regular property name until '.', '[', or end
                var propEnd = index
                while propEnd < str.endIndex && str[propEnd] != "." && str[propEnd] != "[" {
                    propEnd = str.index(after: propEnd)
                }
                let propName = String(str[index..<propEnd]).trimmingCharacters(in: .whitespaces)
                if propName == "*" {
                    segments.append(.wildcard)
                } else if !propName.isEmpty {
                    segments.append(.property(propName))
                }
                index = propEnd
            }
        }

        return segments
    }

    private static func extractKeysFromBracket(_ inner: String) -> [String] {
        // Matches quoted strings like 'foo', "bar"
        var keys: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "'"

        for ch in inner {
            if inQuote {
                if ch == quoteChar {
                    inQuote = false
                    keys.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "'" || ch == "\"" {
                    inQuote = true
                    quoteChar = ch
                }
            }
        }

        if keys.isEmpty {
            // Unquoted single key
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                keys.append(trimmed)
            }
        }
        return keys
    }

    private static func evaluateSegments(current: [Any], segments: ArraySlice<PathSegment>) -> [Any] {
        guard let first = segments.first else { return current }
        let remaining = segments.dropFirst()

        switch first {
        case .property(let key):
            var next: [Any] = []
            for item in current {
                if let dict = item as? [String: Any], let val = dict[key] {
                    next.append(val)
                }
            }
            return evaluateSegments(current: next, segments: remaining)

        case .index(let idx):
            var next: [Any] = []
            for item in current {
                if let arr = item as? [Any], idx >= 0 && idx < arr.count {
                    next.append(arr[idx])
                }
            }
            return evaluateSegments(current: next, segments: remaining)

        case .wildcard:
            var next: [Any] = []
            for item in current {
                if let arr = item as? [Any] {
                    next.append(contentsOf: arr)
                } else if let dict = item as? [String: Any] {
                    next.append(contentsOf: dict.values)
                }
            }
            return evaluateSegments(current: next, segments: remaining)

        case .multiProperty(let keys):
            var next: [Any] = []
            for item in current {
                if let dict = item as? [String: Any] {
                    // First matching key is picked per item
                    for key in keys {
                        if let val = dict[key] {
                            next.append(val)
                            break
                        }
                    }
                }
            }
            return evaluateSegments(current: next, segments: remaining)

        case .recursiveDescent:
            var next: [Any] = []
            for item in current {
                next.append(contentsOf: collectAllDescendants(item))
            }
            return evaluateSegments(current: next, segments: remaining)
        }
    }

    private static func collectAllDescendants(_ item: Any) -> [Any] {
        var results: [Any] = [item]
        if let dict = item as? [String: Any] {
            for val in dict.values {
                results.append(contentsOf: collectAllDescendants(val))
            }
        } else if let arr = item as? [Any] {
            for val in arr {
                results.append(contentsOf: collectAllDescendants(val))
            }
        }
        return results
    }
}
