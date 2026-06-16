import Foundation

/// Local heuristic gate that decides whether to surface a suggestion.
/// Replaces the LLM-based surfacing gate for sub-100ms decisions.
struct RealtimeGate: Sendable {
    /// Evaluate whether a suggestion should surface.
    func evaluate(
        text: String,
        speaker: Speaker,
        contextPacks: [KBContextPack],
        kbSimilarityThreshold: Double,
        questionDensity: Double,
        recentSuggestionTexts: [String]
    ) -> GateResult {
        let topScore = contextPacks.first?.score ?? 0
        let triggerKind = detectTriggerKind(text)

        if contextPacks.isEmpty {
            // Transcript-only mode: surface only on strong conversational triggers
            guard triggerKind == .question || triggerKind == .claim else {
                return GateResult(shouldSurface: false, triggerKind: triggerKind, score: 0, reason: "No KB and weak trigger")
            }

            // Duplicate suppression against recent suggestions
            for recent in recentSuggestionTexts.suffix(3) {
                if TextSimilarity.jaccard(text, recent) > 0.7 {
                    return GateResult(shouldSurface: false, triggerKind: triggerKind, score: 0, reason: "Duplicate of recent suggestion")
                }
            }

            let transcriptScore = (questionDensity * 0.6) + (triggerKind == .question ? 0.4 : 0.2)
            return GateResult(shouldSurface: true, triggerKind: triggerKind, score: transcriptScore, reason: "Transcript-only trigger")
        }

        // KB similarity threshold
        guard topScore >= kbSimilarityThreshold else {
            return GateResult(shouldSurface: false, triggerKind: .general, score: topScore, reason: "KB score below threshold")
        }

        // Duplicate suppression: Jaccard similarity against recent suggestions
        let candidateText = contextPacks.first?.matchedText ?? ""
        for recent in recentSuggestionTexts.suffix(3) {
            if TextSimilarity.jaccard(candidateText, recent) > 0.7 {
                return GateResult(shouldSurface: false, triggerKind: triggerKind, score: topScore, reason: "Duplicate of recent suggestion")
            }
        }

        // Combined score for burst/decay
        let combinedScore = (questionDensity * 0.4) + (topScore * 0.6)

        return GateResult(
            shouldSurface: true,
            triggerKind: triggerKind,
            score: combinedScore,
            reason: "Passed heuristic gate"
        )
    }

    struct GateResult: Sendable {
        let shouldSurface: Bool
        let triggerKind: RealtimeTriggerKind
        let score: Double
        let reason: String
    }

    // MARK: - Trigger Detection

    private func detectTriggerKind(_ text: String) -> RealtimeTriggerKind {
        let lower = text.lowercased()

        // Question markers
        if lower.contains("?") { return .question }
        let questionStarts = ["what ", "how ", "why ", "should ", "could ", "would ", "do you think", "which ", "can you ", "when "]
        for start in questionStarts {
            if lower.hasPrefix(start) { return .question }
        }

        // Decision markers
        let decisionPhrases = ["should we", "let's go with", "i think we should", "we need to decide", "which one"]
        for phrase in decisionPhrases {
            if lower.contains(phrase) { return .question }
        }

        // Freight quote / commitment markers — the other side stating a rate,
        // an allocation, or a concession is a claim to check against your
        // numbers. Listed before generic claim markers so they win, and so
        // they surface even in transcript-only mode (where .topic never does).
        let freightClaimPhrases = [
            "per container", "per box", "per teu", "per feu", "all-in", "all in",
            "flat rate", "the rate is", "rate will be", "best i can do", "best we can do",
            "we can offer", "we can do", "we can't guarantee", "no space", "no allocation",
            "rolled", "roll over", "rollover", "blank sailing", "free time", "demurrage",
            "detention", "minimum commitment", "subject to space", "general rate increase"
        ]
        for phrase in freightClaimPhrases {
            if lower.contains(phrase) { return .claim }
        }

        // Claim markers
        let claimPhrases = ["i think", "i assume", "i believe", "probably", "but ", "however", "i disagree", "that's not", "the problem is"]
        for phrase in claimPhrases {
            if lower.contains(phrase) { return .claim }
        }

        // Freight topic markers
        let topicPhrases = [
            "rate", "allocation", "capacity", "space", "equipment", "container",
            "transit", "schedule", "surcharge", "bunker", "baf", "gri", "peak season",
            "contract", "spot", "volume", "lane", "carrier", "vessel", "booking", "shipment"
        ]
        for phrase in topicPhrases {
            if lower.contains(phrase) { return .topic }
        }

        return .general
    }

}
