import Foundation

/// Naming and classifying imported project icons, as v1 did.
public enum IconHash {
    /// FNV-1a as 16 hex digits: a stable name for the same file imported twice.
    public static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Whether an SVG uses no color but black, `currentColor` and transparency, so it can be drawn
    /// in any one color without losing anything.
    public static func isOneColorSVG(_ svg: String) -> Bool {
        let neutral: Set<String> = ["none", "currentcolor", "black", "#000", "#000000", "#000f", "#000000ff", "transparent", "inherit"]
        let svg = svg.lowercased()
        return ["fill", "stroke", "stop-color", "color", "flood-color"].allSatisfy { property in
            attributeValues(svg, property).allSatisfy { value in
                let value = value.trimmingCharacters(in: .whitespaces)
                return neutral.contains(value) || value.hasPrefix("url(") || value.isEmpty
            }
        }
    }

    /// Values of `property` set as an attribute (`fill="…"`) or in a style (`fill: …;`).
    static func attributeValues(_ svg: String, _ property: String) -> [String] {
        var values: [String] = []
        var search = svg.startIndex
        while let range = svg.range(of: property, range: search..<svg.endIndex) {
            search = range.upperBound
            // Skip longer names such as `fill-opacity`, and other words ending in it.
            if range.lowerBound > svg.startIndex {
                let before = svg[svg.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber || before == "-" { continue }
            }
            let rest = svg[range.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" }
            if rest.first == "=" {
                let value = rest.dropFirst().drop { $0 == " " }
                guard let quote = value.first, quote == "\"" || quote == "'" else { continue }
                let body = value.dropFirst()
                guard let end = body.firstIndex(of: quote) else { continue }
                values.append(String(body[..<end]))
            } else if rest.first == ":" {
                let body = rest.dropFirst()
                let end = body.firstIndex { ";\"'}".contains($0) } ?? body.endIndex
                values.append(String(body[..<end]))
            }
        }
        return values
    }
}
