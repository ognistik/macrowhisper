//
//  FuzzySearch.swift
//  Macrowhisper Alfred
//
//  Created by AI Assistant on 2025-08-08.
//

import Foundation

struct Fuzzy<Target> {
    let query: String.UnicodeScalarView
    private let adjBonus: Int
    private let sepBonus: Int
    private let camelBonus: Int
    private let leadPenalty: Int
    private let maxLeadPenalty: Int
    private let unmatchedPenalty: Int
    private let separators: Set<UnicodeScalar>
    private let stripDiacritics: Bool
    private let getTargetText: (Target) -> String

    init(
        query: String,
        getTargetText: @escaping (Target) -> String,
        adjBonus: Int = 5,
        sepBonus: Int = 10,
        camelBonus: Int = 10,
        leadPenalty: Int = -3,
        maxLeadPenalty: Int = -9,
        unmatchedPenalty: Int = -1,
        separators: String = "_-.–/ ",
        stripDiacritics: Bool = true
    ) {
        self.query = query.unicodeScalars
        self.getTargetText = getTargetText
        self.adjBonus = adjBonus
        self.sepBonus = sepBonus
        self.camelBonus = camelBonus
        self.leadPenalty = leadPenalty
        self.maxLeadPenalty = maxLeadPenalty
        self.unmatchedPenalty = unmatchedPenalty
        self.separators = Set(separators.unicodeScalars)
        self.stripDiacritics = stripDiacritics && query.allSatisfy({ $0.isASCII })
    }
}

extension Fuzzy {
    struct MatchResult: Comparable, Equatable {
        let isMatch: Bool
        let score: Int
        let query: String
        let targetIndex: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.targetIndex == rhs.targetIndex && lhs.score == rhs.score
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.score < rhs.score }
    }
}

extension Fuzzy {
    func match(in target: Target, index: Int) -> MatchResult {
        let targetString: String = getTargetText(target)
        let targetScalars: String.UnicodeScalarView = {
            stripDiacritics ? targetString.folding(options: [.diacriticInsensitive], locale: nil).unicodeScalars : targetString.unicodeScalars
        }()
        let targetLen: Int = targetScalars.count
        let targetBuffer: ContiguousArray<UnicodeScalar> = .init(targetScalars)

        var score = 0
        var pIdx = 0
        var sIdx = 0
        let pLen = query.count

        var prevMatch = false
        var prevLower = false
        var prevSep = true
        var bestLetter: UnicodeScalar? = nil
        var bestLower: UnicodeScalar? = nil
        var bestLetterScore = 0

        while sIdx < targetLen {
            let pChar: UnicodeScalar? = pIdx < pLen ? query[query.index(query.startIndex, offsetBy: pIdx)] : nil
            let sChar: UnicodeScalar = targetBuffer[sIdx]
            let pLower: UnicodeScalar? = pChar?.properties.lowercaseMapping.unicodeScalars.first
            let sLower: UnicodeScalar = sChar.properties.lowercaseMapping.unicodeScalars.first!
            let sUpper: UnicodeScalar = sChar.properties.uppercaseMapping.unicodeScalars.first!
            let nextMatch: Bool = pChar != nil && pLower == sLower
            let rematch: Bool = bestLetter != nil && bestLower == sLower
            let advanced: Bool = nextMatch && bestLetter != nil
            let pRepeat: Bool = bestLetter != nil && pChar != nil && bestLower == pLower

            if advanced || pRepeat {
                score &+= bestLetterScore
                bestLetter = nil
                bestLower = nil
                bestLetterScore = 0
            }

            if nextMatch || rematch {
                var newScore = 0
                if pIdx == 0 {
                    score &+= max(sIdx &* leadPenalty, maxLeadPenalty)
                }
                if prevMatch { newScore &+= adjBonus }
                if prevSep { newScore &+= sepBonus }
                if prevLower && sChar == sUpper && sLower != sUpper { newScore &+= camelBonus }
                if nextMatch { pIdx &+= 1 }
                if newScore >= bestLetterScore {
                    bestLetter = sChar
                    bestLower = sLower
                    bestLetterScore = newScore
                }
                prevMatch = true
            } else {
                score &+= unmatchedPenalty
                prevMatch = false
            }

            prevLower = sChar == sLower && sLower != sUpper
            prevSep = separators.contains(sChar)
            sIdx &+= 1
        }

        if bestLetter != nil { score &+= bestLetterScore }
        return MatchResult(isMatch: pIdx == pLen, score: score, query: String(query), targetIndex: index)
    }

    func sorted(candidates: [Target], matchesOnly: Bool = true) -> [MatchResult] {
        // If the query is empty, short-circuit to preserve original order
        if query.isEmpty { return candidates.enumerated().map { MatchResult(isMatch: true, score: 0, query: "", targetIndex: $0.offset) } }
        let processedCandidates: [MatchResult] = candidates.enumerated().map { match(in: $0.element, index: $0.offset) }.sorted(by: >)
        return matchesOnly ? processedCandidates.filter(\.isMatch) : processedCandidates
    }
}


