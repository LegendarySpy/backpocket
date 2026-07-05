import Foundation

struct FuzzyResult: Identifiable, Equatable {
    let fact: Fact
    let score: Int
    let matchedIndices: Set<Int>
    var id: UUID { fact.id }
}

enum Fuzzy {
    static func rank(_ query: String, in allFacts: [Fact], limit: Int = 5) -> [FuzzyResult] {
        // Half-filled entries from the editor have nothing to show or type.
        let facts = allFacts.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.isEmpty
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            let recent = facts.sorted { a, b in
                let (ua, ub) = (a.lastUsed ?? .distantPast, b.lastUsed ?? .distantPast)
                return ua != ub ? ua > ub : a.name < b.name
            }
            return recent.prefix(limit).map { FuzzyResult(fact: $0, score: 0, matchedIndices: []) }
        }
        let matches: [FuzzyResult] = facts.compactMap { fact in
            guard let result = match(query: trimmed, candidate: fact.name) else { return nil }
            return FuzzyResult(fact: fact, score: result.score, matchedIndices: result.indices)
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
}
