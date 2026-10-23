import Foundation

enum YORIInterventionIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case posteriorPelvicTilt
    case anteriorPelvicTilt
    case roundedUpperBack
    case incompleteRange
    case poorControl
    case incompleteRangeAndPoorControl

    var localCue: String {
        switch self {
        case .posteriorPelvicTilt:
            "Release the pelvic tuck slightly."
        case .anteriorPelvicTilt:
            "Bring your pelvis a little closer to neutral."
        case .roundedUpperBack:
            "Gently lengthen through your upper spine."
        case .incompleteRange:
            "Try making the spinal curve a little fuller."
        case .poorControl:
            "Slow the transition and move more smoothly."
        case .incompleteRangeAndPoorControl:
            "Use a fuller range and slow the transition."
        }
    }
}

struct YORIInterventionTrigger: Codable, Equatable, Sendable {
    let issue: YORIInterventionIssue
    let persistenceSeconds: TimeInterval
}

enum YORIInterventionSuppressionReason: String, Equatable {
    case inactivePractice
    case notEnoughData
    case userAskAIActive
    case voiceBusy
    case cooldown
    case awaitingRecovery
}

struct YORIInterventionDecision: Equatable {
    let trigger: YORIInterventionTrigger?
    let trackedIssue: YORIInterventionIssue?
    let persistenceSeconds: TimeInterval
    let cooldownRemainingSeconds: TimeInterval
    let suppressionReason: YORIInterventionSuppressionReason?

    static let none = YORIInterventionDecision(
        trigger: nil,
        trackedIssue: nil,
        persistenceSeconds: 0,
        cooldownRemainingSeconds: 0,
        suppressionReason: nil
    )
}

enum YORIInterventionPrototypeConstants {
    // Prototype training-intervention timing from iterative usability testing.
    // These are not pose-recognition, clinical, or pediatric safety thresholds.
    static let mountainPersistenceSeconds: TimeInterval = 2.5
    static let catCowMeaningfulEvaluationIntervalSeconds: TimeInterval = 1
    static let catCowMinimumConsecutiveEvaluations = 3
    static let catCowPersistenceSeconds: TimeInterval = 2
    static let mountainRecoverySeconds: TimeInterval = 1.5
    static let catCowRecoverySeconds: TimeInterval = 2
    static let sameIssueCooldownSeconds: TimeInterval = 18
    static let globalVoiceCooldownSeconds: TimeInterval = 9
}

struct YORIInterventionDecisionEngine {
    private var candidateIssue: YORIInterventionIssue?
    private var candidateStartedAt: TimeInterval?
    private var candidateObservationCount = 0
    private var lastCatCowObservationAt: TimeInterval?

    private var lastGlobalDeliveryAt: TimeInterval?
    private var lastDeliveryByIssue: [YORIInterventionIssue: TimeInterval] = [:]
    private var issuesAwaitingRecovery: Set<YORIInterventionIssue> = []
    private var issueAbsentSince: [YORIInterventionIssue: TimeInterval] = [:]

    mutating func reset() {
        candidateIssue = nil
        candidateStartedAt = nil
        candidateObservationCount = 0
        lastCatCowObservationAt = nil
        lastGlobalDeliveryAt = nil
        lastDeliveryByIssue = [:]
        issuesAwaitingRecovery = []
        issueAbsentSince = [:]
    }

    mutating func suspendPersistence() {
        resetCandidate()
        lastCatCowObservationAt = nil
    }

    mutating func recordUserInteractionEnded(at timestamp: TimeInterval) {
        lastGlobalDeliveryAt = timestamp
    }

    mutating func recordDelivered(
        _ trigger: YORIInterventionTrigger,
        at timestamp: TimeInterval
    ) {
        lastGlobalDeliveryAt = timestamp
        lastDeliveryByIssue[trigger.issue] = timestamp
        issuesAwaitingRecovery.insert(trigger.issue)
        issueAbsentSince[trigger.issue] = nil
    }

    mutating func evaluate(
        result: YORILiveEvaluationResult,
        at timestamp: TimeInterval,
        isPracticeActive: Bool,
        isUserAskAIActive: Bool,
        isVoiceBusy: Bool
    ) -> YORIInterventionDecision {
        guard isPracticeActive else {
            suspendPersistence()
            return decision(suppressionReason: .inactivePractice, at: timestamp)
        }

        if case let .catCow(evaluation) = result,
           !evaluation.poseResult.hasEnoughDataForEvaluation {
            resetCandidate()
            return decision(suppressionReason: .notEnoughData, at: timestamp)
        }

        updateRecovery(using: result, at: timestamp)
        let issue = Self.prioritizedIssue(in: result)

        guard let issue else {
            resetCandidate()
            return .none
        }

        let isMeaningfulObservation = recordCandidateObservation(
            issue: issue,
            result: result,
            at: timestamp
        )
        let persistence = max(0, timestamp - (candidateStartedAt ?? timestamp))

        guard issueIsPersistent(
            issue: issue,
            result: result,
            persistenceSeconds: persistence,
            isMeaningfulObservation: isMeaningfulObservation
        ) else {
            return decision(at: timestamp)
        }

        if isUserAskAIActive {
            return decision(suppressionReason: .userAskAIActive, at: timestamp)
        }
        if isVoiceBusy {
            return decision(suppressionReason: .voiceBusy, at: timestamp)
        }
        if issuesAwaitingRecovery.contains(issue) {
            return decision(suppressionReason: .awaitingRecovery, at: timestamp)
        }

        let cooldownRemaining = cooldownRemaining(for: issue, at: timestamp)
        guard cooldownRemaining <= 0 else {
            return decision(
                suppressionReason: .cooldown,
                cooldownRemaining: cooldownRemaining,
                at: timestamp
            )
        }

        return YORIInterventionDecision(
            trigger: YORIInterventionTrigger(
                issue: issue,
                persistenceSeconds: persistence
            ),
            trackedIssue: issue,
            persistenceSeconds: persistence,
            cooldownRemainingSeconds: 0,
            suppressionReason: nil
        )
    }

    static func isRelevant(
        _ issue: YORIInterventionIssue,
        to result: YORILiveEvaluationResult
    ) -> Bool {
        switch (issue, result) {
        case (.posteriorPelvicTilt, .mountain(let evaluation)):
            evaluation.poseResult.state == .posteriorPelvicTilt
        case (.anteriorPelvicTilt, .mountain(let evaluation)):
            evaluation.poseResult.state == .anteriorPelvicTilt
        case (.roundedUpperBack, .mountain(let evaluation)):
            evaluation.poseResult.state == .roundedUpperBack
        case (.incompleteRange, .catCow(let evaluation)):
            evaluation.poseResult.hasEnoughDataForEvaluation
                && evaluation.poseResult.issues.contains(.incompleteRange)
        case (.poorControl, .catCow(let evaluation)):
            evaluation.poseResult.hasEnoughDataForEvaluation
                && evaluation.poseResult.issues.contains(.poorControl)
        case (.incompleteRangeAndPoorControl, .catCow(let evaluation)):
            evaluation.poseResult.hasEnoughDataForEvaluation
                && evaluation.poseResult.issues.contains(.incompleteRange)
                && evaluation.poseResult.issues.contains(.poorControl)
        default:
            false
        }
    }

    static func prioritizedIssue(
        in result: YORILiveEvaluationResult
    ) -> YORIInterventionIssue? {
        switch result {
        case .mountain(let evaluation):
            switch evaluation.poseResult.state {
            case .posteriorPelvicTilt:
                return YORIInterventionIssue.posteriorPelvicTilt
            case .anteriorPelvicTilt:
                return YORIInterventionIssue.anteriorPelvicTilt
            case .roundedUpperBack:
                return YORIInterventionIssue.roundedUpperBack
            case .correct:
                return nil
            }
        case .catCow(let evaluation):
            guard evaluation.poseResult.hasEnoughDataForEvaluation else { return nil }
            let issues = Set(evaluation.poseResult.issues)
            if issues.contains(.incompleteRange), issues.contains(.poorControl) {
                return .incompleteRangeAndPoorControl
            }
            if issues.contains(.poorControl) {
                return .poorControl
            }
            if issues.contains(.incompleteRange) {
                return .incompleteRange
            }
            return nil
        }
    }

    private mutating func recordCandidateObservation(
        issue: YORIInterventionIssue,
        result: YORILiveEvaluationResult,
        at timestamp: TimeInterval
    ) -> Bool {
        if candidateIssue != issue {
            candidateIssue = issue
            candidateStartedAt = timestamp
            candidateObservationCount = 0
            lastCatCowObservationAt = nil
        }

        switch result {
        case .mountain:
            candidateObservationCount += 1
            return true
        case .catCow:
            guard
                lastCatCowObservationAt == nil
                    || timestamp - (lastCatCowObservationAt ?? timestamp)
                    >= YORIInterventionPrototypeConstants
                        .catCowMeaningfulEvaluationIntervalSeconds
            else {
                return false
            }
            lastCatCowObservationAt = timestamp
            candidateObservationCount += 1
            return true
        }
    }

    private func issueIsPersistent(
        issue: YORIInterventionIssue,
        result: YORILiveEvaluationResult,
        persistenceSeconds: TimeInterval,
        isMeaningfulObservation: Bool
    ) -> Bool {
        switch result {
        case .mountain:
            persistenceSeconds >= YORIInterventionPrototypeConstants
                .mountainPersistenceSeconds
        case .catCow:
            isMeaningfulObservation
                && candidateObservationCount >= YORIInterventionPrototypeConstants
                    .catCowMinimumConsecutiveEvaluations
                && persistenceSeconds >= YORIInterventionPrototypeConstants
                    .catCowPersistenceSeconds
        }
    }

    private mutating func updateRecovery(
        using result: YORILiveEvaluationResult,
        at timestamp: TimeInterval
    ) {
        for issue in Array(issuesAwaitingRecovery) {
            if Self.isRelevant(issue, to: result) {
                issueAbsentSince[issue] = nil
                continue
            }

            let absentSince = issueAbsentSince[issue] ?? timestamp
            issueAbsentSince[issue] = absentSince
            let requiredRecovery: TimeInterval
            switch result {
            case .mountain:
                requiredRecovery = YORIInterventionPrototypeConstants.mountainRecoverySeconds
            case .catCow:
                requiredRecovery = YORIInterventionPrototypeConstants.catCowRecoverySeconds
            }

            if timestamp - absentSince >= requiredRecovery {
                issuesAwaitingRecovery.remove(issue)
                issueAbsentSince[issue] = nil
            }
        }
    }

    private func cooldownRemaining(
        for issue: YORIInterventionIssue,
        at timestamp: TimeInterval
    ) -> TimeInterval {
        let globalRemaining = lastGlobalDeliveryAt.map {
            YORIInterventionPrototypeConstants.globalVoiceCooldownSeconds
                - (timestamp - $0)
        } ?? 0
        let issueRemaining = lastDeliveryByIssue[issue].map {
            YORIInterventionPrototypeConstants.sameIssueCooldownSeconds
                - (timestamp - $0)
        } ?? 0
        return max(0, max(globalRemaining, issueRemaining))
    }

    private func decision(
        suppressionReason: YORIInterventionSuppressionReason? = nil,
        cooldownRemaining: TimeInterval? = nil,
        at timestamp: TimeInterval
    ) -> YORIInterventionDecision {
        let persistence = max(0, timestamp - (candidateStartedAt ?? timestamp))
        return YORIInterventionDecision(
            trigger: nil,
            trackedIssue: candidateIssue,
            persistenceSeconds: persistence,
            cooldownRemainingSeconds: cooldownRemaining
                ?? candidateIssue.map { self.cooldownRemaining(for: $0, at: timestamp) }
                ?? 0,
            suppressionReason: suppressionReason
        )
    }

    private mutating func resetCandidate() {
        candidateIssue = nil
        candidateStartedAt = nil
        candidateObservationCount = 0
        lastCatCowObservationAt = nil
    }
}

#if DEBUG
enum YORIInterventionDecisionEngineDevelopmentChecks {
    static func run() {
        mountainPersistenceAndCooldown()
        catCowPersistence()
        cooldownSuppression()
        suppressionStates()
    }

    private static func mountainPersistenceAndCooldown() {
        var engine = YORIInterventionDecisionEngine()
        let rounded = mountain(.roundedUpperBack)
        precondition(engine.evaluate(
            result: rounded,
            at: 0,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger == nil)
        precondition(engine.evaluate(
            result: rounded,
            at: 2.4,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger == nil)
        let trigger = engine.evaluate(
            result: rounded,
            at: 2.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger
        precondition(trigger?.issue == .roundedUpperBack)
        engine.recordDelivered(trigger!, at: 2.5)
        precondition(engine.evaluate(
            result: rounded,
            at: 25,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).suppressionReason == .awaitingRecovery)

        _ = engine.evaluate(
            result: mountain(.correct),
            at: 26,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        _ = engine.evaluate(
            result: mountain(.correct),
            at: 27.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        _ = engine.evaluate(
            result: rounded,
            at: 28,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        precondition(engine.evaluate(
            result: rounded,
            at: 30.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger?.issue == .roundedUpperBack)
    }

    private static func catCowPersistence() {
        var engine = YORIInterventionDecisionEngine()
        let poorControl = catCow([.poorControl], enoughData: true)
        precondition(engine.evaluate(
            result: poorControl,
            at: 0,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger == nil)
        precondition(engine.evaluate(
            result: poorControl,
            at: 1,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger == nil)
        precondition(engine.evaluate(
            result: poorControl,
            at: 2,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger?.issue == .poorControl)
    }

    private static func cooldownSuppression() {
        let rounded = mountain(.roundedUpperBack)
        let correct = mountain(.correct)

        var sameIssueEngine = YORIInterventionDecisionEngine()
        _ = sameIssueEngine.evaluate(
            result: rounded,
            at: 0,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        let firstTrigger = sameIssueEngine.evaluate(
            result: rounded,
            at: 2.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger!
        sameIssueEngine.recordDelivered(firstTrigger, at: 2.5)
        _ = sameIssueEngine.evaluate(
            result: correct,
            at: 3,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        _ = sameIssueEngine.evaluate(
            result: correct,
            at: 4.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        _ = sameIssueEngine.evaluate(
            result: rounded,
            at: 5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        precondition(sameIssueEngine.evaluate(
            result: rounded,
            at: 7.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).suppressionReason == .cooldown)
        precondition(sameIssueEngine.evaluate(
            result: rounded,
            at: 20.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger?.issue == .roundedUpperBack)

        var globalEngine = YORIInterventionDecisionEngine()
        _ = globalEngine.evaluate(
            result: rounded,
            at: 0,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        let delivered = globalEngine.evaluate(
            result: rounded,
            at: 2.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).trigger!
        globalEngine.recordDelivered(delivered, at: 2.5)
        let anterior = mountain(.anteriorPelvicTilt)
        _ = globalEngine.evaluate(
            result: anterior,
            at: 3,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        precondition(globalEngine.evaluate(
            result: anterior,
            at: 5.5,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).suppressionReason == .cooldown)
    }

    private static func suppressionStates() {
        var askEngine = YORIInterventionDecisionEngine()
        let rounded = mountain(.roundedUpperBack)
        _ = askEngine.evaluate(
            result: rounded,
            at: 0,
            isPracticeActive: true,
            isUserAskAIActive: false,
            isVoiceBusy: false
        )
        precondition(askEngine.evaluate(
            result: rounded,
            at: 2.5,
            isPracticeActive: true,
            isUserAskAIActive: true,
            isVoiceBusy: false
        ).suppressionReason == .userAskAIActive)

        var pausedEngine = YORIInterventionDecisionEngine()
        precondition(pausedEngine.evaluate(
            result: rounded,
            at: 0,
            isPracticeActive: false,
            isUserAskAIActive: false,
            isVoiceBusy: false
        ).suppressionReason == .inactivePractice)
    }

    private static func mountain(_ state: YORIMountainState) -> YORILiveEvaluationResult {
        .mountain(
            YORILiveMountainEvaluation(
                poseResult: YORIMountainResult(
                    state: state,
                    upperSpinePitch: 0,
                    lowerSpinePitch: 0,
                    upperSpineRoll: 0,
                    lowerSpineRoll: 0
                ),
                pressureResult: nil
            )
        )
    }

    private static func catCow(
        _ issues: [YORICatCowIssue],
        enoughData: Bool
    ) -> YORILiveEvaluationResult {
        .catCow(
            YORILiveCatCowEvaluation(
                poseResult: YORICatCowResult(
                    issues: issues,
                    windowDuration: enoughData ? 16 : 0,
                    frameCount: enoughData ? 100 : 1,
                    upperRange: 20,
                    lowerRange: 10,
                    wholeRange: 24,
                    gyroRMS: 35,
                    gyroPeak: 50,
                    emg1ActivationPercent: nil,
                    emg2ActivationPercent: nil,
                    hasEnoughDataForEvaluation: enoughData
                ),
                pressureResult: nil
            )
        )
    }
}
#endif
