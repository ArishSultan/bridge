/// Fuzzy matching for history search and completions: the query's characters in order, case
/// insensitive, scored to prefer word starts, runs, early matches, exact-case prefixes and short
/// candidates. Scores match v1.
public enum Fuzzy {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Matched character offsets in the candidate.
        public let positions: [Int]
    }

    public static func match(_ query: String, _ candidate: String) -> Match? {
        if query.isEmpty { return Match(score: 0, positions: []) }
        let wanted = Array(query.lowercased())
        let chars = Array(candidate)
        var positions: [Int] = []
        positions.reserveCapacity(wanted.count)
        var score = 0
        var next = 0
        var previous: Int?

        for want in wanted {
            guard let found = (next..<chars.count).first(where: { chars[$0].lowercased() == String(want) }) else {
                return nil
            }
            let boundary = found == 0 || " /-_.:=".contains(chars[found - 1])
            score += 10
            if boundary { score += 20 }
            if let previous {
                if previous + 1 == found {
                    score += 15
                } else {
                    score -= min(found - previous - 1, 10)
                }
            } else {
                score -= min(found, 15)
            }
            positions.append(found)
            previous = found
            next = found + 1
        }
        // Prefer exact-case prefixes and shorter candidates.
        if candidate.hasPrefix(String(wanted)) { score += 25 }
        score -= min(chars.count / 8, 10)
        return Match(score: score, positions: positions)
    }
}
