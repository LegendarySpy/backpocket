import Foundation

struct FuzzyResult: Identifiable, Equatable {
    let fact: Fact
    let score: Int
    let matchedIndices: Set<Int>
    var id: UUID { fact.id }
}

enum Fuzzy {
    static func rank(
        _ query: String,
        in allFacts: [Fact],
        context appIdentifier: String? = nil,
        limit: Int = 4,
        now: Date = Date()
    ) -> [FuzzyResult] {
        // Half-filled entries from the editor have nothing to show or type.
        let facts = allFacts.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            let recent = facts.sorted { a, b in
                let scoreA = usageScore(for: a, context: appIdentifier, now: now)
                let scoreB = usageScore(for: b, context: appIdentifier, now: now)
                if scoreA != scoreB { return scoreA > scoreB }
                let (ua, ub) = (a.lastUsed ?? .distantPast, b.lastUsed ?? .distantPast)
                if ua != ub { return ua > ub }
                return a.name < b.name
            }
            return recent.prefix(limit).map {
                FuzzyResult(
                    fact: $0,
                    score: usageScore(for: $0, context: appIdentifier, now: now),
                    matchedIndices: []
                )
            }
        }
        let matches: [FuzzyResult] = facts.compactMap { fact in
            guard let result = match(query: trimmed, candidate: fact.name) else { return nil }
            return FuzzyResult(
                fact: fact,
                score: result.score * 20 + usageScore(for: fact, context: appIdentifier, now: now),
                matchedIndices: result.indices
            )
        }
        let ranked = matches.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.fact.name < b.fact.name
        }
        return Array(ranked.prefix(limit))
    }

    static func match(query: String, candidate: String) -> (score: Int, indices: Set<Int>)? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        guard !q.isEmpty, !c.isEmpty else { return nil }

        var score = 0
        var indices = Set<Int>()
        var qi = 0
        var lastMatch = -2

        for ci in c.indices {
            guard qi < q.count, c[ci] == q[qi] else { continue }
            var bonus = 1
            if ci == lastMatch + 1 { bonus += 3 }
            let atBoundary = ci == 0
                || c[ci - 1] == " " || c[ci - 1] == "-" || c[ci - 1] == "_"
                || (original[ci].isUppercase && original[ci - 1].isLowercase)
            if atBoundary { bonus += 4 }
            if ci == 0 { bonus += 2 }
            score += bonus
            indices.insert(ci)
            lastMatch = ci
            qi += 1
        }

        guard qi == q.count else { return nil }
        score -= max(0, c.count - q.count) / 4
        return (score, indices)
    }

    private static func usageScore(for fact: Fact, context appIdentifier: String?, now: Date) -> Int {
        var score = recencyScore(lastUsed: fact.lastUsed, now: now)
        score += frequencyScore(count: fact.useCount, weight: 8)

        guard let appIdentifier, let appUsage = fact.appUsage[appIdentifier] else { return score }
        score += recencyScore(lastUsed: appUsage.lastUsed, now: now) * 2
        score += frequencyScore(count: appUsage.count, weight: 18)
        return score
    }

    private static func frequencyScore(count: Int, weight: Double) -> Int {
        guard count > 0 else { return 0 }
        return Int((log2(Double(count) + 1) * weight).rounded())
    }

    private static func recencyScore(lastUsed: Date?, now: Date) -> Int {
        guard let lastUsed else { return 0 }
        let age = max(0, now.timeIntervalSince(lastUsed))
        switch age {
        case 0..<(60 * 60): return 60
        case 0..<(60 * 60 * 24): return 45
        case 0..<(60 * 60 * 24 * 7): return 30
        case 0..<(60 * 60 * 24 * 30): return 18
        case 0..<(60 * 60 * 24 * 90): return 8
        default: return 2
        }
    }
}
