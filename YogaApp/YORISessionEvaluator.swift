import Foundation

struct YORISessionResult: Equatable {
    let pose: YORILivePose
    let durationSeconds: Double
    #if DEBUG
    // Diagnostic-only raw scores are absent from Release builds.
    let rawScores: YORISessionDimensionScores
    #endif
    let alignmentScore: Double
    let stabilityScore: Double
    let controlScore: Double
    let overallScore: Double
    let mainFeedback: String
    let mountainMetrics: YORIMountainSessionMetrics?
    let catCowMetrics: YORICatCowSessionMetrics?

    init(
        pose: YORILivePose,
        durationSeconds: Double,
        rawScores: YORISessionDimensionScores,
        alignmentScore: Double,
        stabilityScore: Double,
        controlScore: Double,
        overallScore: Double,
        mainFeedback: String,
        mountainMetrics: YORIMountainSessionMetrics?,
        catCowMetrics: YORICatCowSessionMetrics?
    ) {
        self.pose = pose
        self.durationSeconds = durationSeconds
        #if DEBUG
        self.rawScores = rawScores
        #else
        _ = rawScores
        #endif
        self.alignmentScore = alignmentScore
        self.stabilityScore = stabilityScore
        self.controlScore = controlScore
        self.overallScore = overallScore
        self.mainFeedback = mainFeedback
        self.mountainMetrics = mountainMetrics
        self.catCowMetrics = catCowMetrics
    }
}

struct YORIMountainSessionMetrics: Equatable {
    let sampleCount: Int
    let correctTimeRatio: Double
    let roundedTimeRatio: Double
    let anteriorTiltTimeRatio: Double
    let posteriorTiltTimeRatio: Double
    let meanUpperSpinePitch: Double
    let meanLowerSpinePitch: Double
    let relativeAngleVariability: Double
    let orientationVariability: Double
    let orientationDrift: Double
    let gyroRMS: Double
    let gyroPeak: Double
    let excessiveCorrectionCount: Int
    let stateSwitchCount: Int
    let footPressureSymmetry: Double?
    let emg1ActivationPercent: Double?
    let emg2ActivationPercent: Double?
}

struct YORICatCowSessionMetrics: Equatable {
    let validEvaluationWindowCount: Int
    let incompleteRangeRatio: Double
    let poorControlRatio: Double
    let meanUpperRange: Double
    let meanLowerRange: Double
    let meanWholeRange: Double
    let upperRangeVariability: Double
    let wholeRangeVariability: Double
    let meanGyroRMS: Double
    let meanGyroPeak: Double
    let robustGyroPeak: Double
    let rmsQualityScore: Double
    let peakQualityScore: Double
    let temporalControlScore: Double
    let gyroConsistency: Double
    let handPressureSymmetry: Double?
    let emg1ActivationPercent: Double?
    let emg2ActivationPercent: Double?
}

enum YORISessionScoringConstants {
    // Prototype training-score constants only. These are not clinical diagnostic
    // thresholds or validated pediatric normative values.
    static let minimumMountainDurationSeconds: TimeInterval = 1
    static let minimumMountainSamples = 10
    static let minimumMountainGyroSamples = 10
    static let minimumCatCowEvaluationWindows = 3
    static let minimumCatCowEvaluationSpanSeconds: TimeInterval = 1
    static let catCowEvaluationIntervalSeconds: TimeInterval = 0.5
    static let strongPerformanceScore = 85.0

    static let mountainContinuousDeviationPenalty = 25.0
    static let mountainAlignmentClassificationWeight = 0.75
    static let mountainAlignmentContinuousWeight = 0.25
    static let mountainOrientationVariabilityPenalty = 12.5
    static let mountainRelativeAngleVariabilityPenalty = 20.0
    static let mountainOrientationDriftPenalty = 10.0
    static let mountainStabilityOrientationWeight = 0.45
    static let mountainStabilityRelativeAngleWeight = 0.35
    static let mountainStabilityDriftWeight = 0.20
    static let optionalPressureWeight = 0.15
    static let flexOnlyWeightWithPressure = 0.85
    static let mountainExcessiveCorrectionGyro = 18.0
    static let mountainGyroRMSPenalty = 5.0
    static let mountainGyroPeakPenalty = 100.0 / 60.0
    static let mountainCorrectionRatePenalty = 100.0 / 12.0
    static let mountainStateSwitchRatePenalty = 100.0 / 12.0
    static let mountainControlGyroRMSWeight = 0.45
    static let mountainControlGyroPeakWeight = 0.20
    static let mountainControlCorrectionWeight = 0.20
    static let mountainControlStateSwitchWeight = 0.15

    static let catCowUpperRangeVariabilityLimit = 12.0
    static let catCowWholeRangeVariabilityLimit = 10.0
    static let catCowAlignmentRangeWeight = 0.80
    static let catCowAlignmentIssueWeight = 0.20

    // Session-score calibration only. These prototype anchors intentionally do
    // not alter the live Cat-Cow poor-control threshold in YORIPoseEngine.
    static let catCowRMSFullQualityMaximum = 25.0
    static let catCowRMSPoorControlBoundary = 33.0
    static let catCowRMSModerateMaximum = 45.0
    static let catCowRMSLowMaximum = 60.0
    static let catCowRMSZeroQuality = 70.0
    static let catCowPeakFullQualityMaximum = 60.0
    static let catCowPeakGoodMaximum = 100.0
    static let catCowPeakModerateMaximum = 160.0
    static let catCowPeakLowMaximum = 220.0
    static let catCowPeakZeroQuality = 260.0
    static let catCowRobustPeakPercentile = 0.90
    static let catCowControlRMSQualityWeight = 0.60
    static let catCowControlPeakQualityWeight = 0.20
    static let catCowControlTemporalWeight = 0.20
    static let catCowStabilityUpperRangeWeight = 0.40
    static let catCowStabilityWholeRangeWeight = 0.40
    static let catCowStabilityGyroWeight = 0.20
}

final class YORISessionEvaluator {
    private struct RunningMoments {
        private(set) var count = 0
        private(set) var mean = 0.0
        private var sumSquaredDifference = 0.0

        var populationStandardDeviation: Double {
            guard count > 0 else { return 0 }
            return sqrt(sumSquaredDifference / Double(count))
        }

        mutating func add(_ value: Double) {
            count += 1
            let delta = value - mean
            mean += delta / Double(count)
            let nextDelta = value - mean
            sumSquaredDifference += delta * nextDelta
        }
    }

    private struct MountainAccumulator {
        var sampleCount = 0
        var stateCounts: [YORIMountainState: Int] = [:]
        var previousState: YORIMountainState?
        var stateSwitchCount = 0
        var severityTotal = 0.0
        var upperPitch = RunningMoments()
        var lowerPitch = RunningMoments()
        var upperRoll = RunningMoments()
        var lowerRoll = RunningMoments()
        var orientations = Array(repeating: RunningMoments(), count: 6)
        var firstOrientation: [Double]?
        var lastOrientation: [Double]?
        var lastSequence: UInt16?
        var gyroSampleCount = 0
        var gyroSquaredTotal = 0.0
        var gyroPeak = 0.0
        var isAboveCorrectionThreshold = false
        var excessiveCorrectionCount = 0
        var pressureSymmetry = RunningMoments()
    }

    private struct CatCowAccumulator {
        var validEvaluationWindowCount = 0
        var incompleteRangeCount = 0
        var poorControlCount = 0
        var upperRange = RunningMoments()
        var lowerRange = RunningMoments()
        var wholeRange = RunningMoments()
        var gyroRMS = RunningMoments()
        var gyroPeak = RunningMoments()
        var gyroPeakValues: [Double] = []
        var rangeScoreTotal = 0.0
        var emg1Activation = RunningMoments()
        var emg2Activation = RunningMoments()
        var pressureSymmetry = RunningMoments()
        var firstEvaluationTimestamp: TimeInterval?
        var lastEvaluationTimestamp: TimeInterval?
    }

    private struct ActiveSession {
        let pose: YORILivePose
        var accumulatedDuration: TimeInterval = 0
        var activeStartedAt: TimeInterval?
        var mountain = MountainAccumulator()
        var catCow = CatCowAccumulator()
    }

    private let now: () -> TimeInterval
    private var session: ActiveSession?

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    func startSession(pose: YORILivePose) {
        session = ActiveSession(pose: pose, activeStartedAt: now())
    }

    func pauseSession() {
        guard var session, let activeStartedAt = session.activeStartedAt else { return }
        session.accumulatedDuration += max(0, now() - activeStartedAt)
        session.activeStartedAt = nil
        self.session = session
    }

    func resumeSession() {
        guard var session, session.activeStartedAt == nil else { return }
        session.activeStartedAt = now()
        self.session = session
    }

    func cancelSession() {
        session = nil
    }

    func ingestMountain(
        result: YORIMountainResult,
        sample: YORIFlexMainSensorSample
    ) {
        guard var session, session.pose == .mountain, session.activeStartedAt != nil else { return }
        guard session.mountain.lastSequence != sample.sequence else { return }

        var mountain = session.mountain
        mountain.lastSequence = sample.sequence
        mountain.sampleCount += 1
        mountain.stateCounts[result.state, default: 0] += 1
        if let previousState = mountain.previousState, previousState != result.state {
            mountain.stateSwitchCount += 1
        }
        mountain.previousState = result.state

        mountain.upperPitch.add(result.upperSpinePitch)
        mountain.lowerPitch.add(result.lowerSpinePitch)
        mountain.upperRoll.add(result.upperSpineRoll)
        mountain.lowerRoll.add(result.lowerSpineRoll)

        let orientation = [
            sample.t3Roll, sample.t3Pitch,
            sample.t12Roll, sample.t12Pitch,
            sample.s1Roll, sample.s1Pitch
        ]
        if mountain.firstOrientation == nil {
            mountain.firstOrientation = orientation
        }
        mountain.lastOrientation = orientation
        for index in orientation.indices {
            mountain.orientations[index].add(orientation[index])
        }

        let roundedSeverity = max(result.upperSpinePitch, 0)
            / YORIPoseEngineThresholds.mountainRoundedUpperBackPitchMinimum
        let anteriorSeverity = max(result.lowerSpinePitch, 0)
            / YORIPoseEngineThresholds.mountainAnteriorPelvicTiltLowerPitchMinimum
        let posteriorLowerSeverity = max(-result.lowerSpinePitch, 0)
            / abs(YORIPoseEngineThresholds.mountainPosteriorPelvicTiltLowerPitchMaximum)
        let posteriorUpperSeverity = max(result.upperSpinePitch, 0)
            / YORIPoseEngineThresholds.mountainPosteriorPelvicTiltUpperPitchMinimum
        mountain.severityTotal += max(
            roundedSeverity,
            anteriorSeverity,
            min(posteriorLowerSeverity, posteriorUpperSeverity)
        )

        session.mountain = mountain
        self.session = session
    }

    func ingestGyroscope(_ sample: YORIFlexGyroscopeSample) {
        guard var session, session.pose == .mountain, session.activeStartedAt != nil else { return }
        var mountain = session.mountain
        let magnitude = sqrt(
            sample.t3.magnitude * sample.t3.magnitude
                + sample.t12.magnitude * sample.t12.magnitude
                + sample.s1.magnitude * sample.s1.magnitude
        )

        mountain.gyroSampleCount += 1
        mountain.gyroSquaredTotal += magnitude * magnitude
        mountain.gyroPeak = max(mountain.gyroPeak, magnitude)

        let isAboveThreshold = magnitude
            > YORISessionScoringConstants.mountainExcessiveCorrectionGyro
        if isAboveThreshold, !mountain.isAboveCorrectionThreshold {
            mountain.excessiveCorrectionCount += 1
        }
        mountain.isAboveCorrectionThreshold = isAboveThreshold

        session.mountain = mountain
        self.session = session
    }

    func ingestCatCow(
        result: YORICatCowResult,
        timestamp: TimeInterval
    ) {
        guard
            result.hasEnoughDataForEvaluation,
            var session,
            session.pose == .catCow,
            session.activeStartedAt != nil
        else {
            return
        }

        var catCow = session.catCow
        if let lastTimestamp = catCow.lastEvaluationTimestamp,
           timestamp - lastTimestamp < YORISessionScoringConstants.catCowEvaluationIntervalSeconds {
            return
        }

        catCow.firstEvaluationTimestamp = catCow.firstEvaluationTimestamp ?? timestamp
        catCow.lastEvaluationTimestamp = timestamp
        catCow.validEvaluationWindowCount += 1
        if result.issues.contains(.incompleteRange) {
            catCow.incompleteRangeCount += 1
        }
        if result.issues.contains(.poorControl) {
            catCow.poorControlCount += 1
        }

        catCow.upperRange.add(result.upperRange)
        catCow.lowerRange.add(result.lowerRange)
        catCow.wholeRange.add(result.wholeRange)
        catCow.gyroRMS.add(result.gyroRMS)
        catCow.gyroPeak.add(result.gyroPeak)
        catCow.gyroPeakValues.append(result.gyroPeak)
        if let activation = result.emg1ActivationPercent {
            catCow.emg1Activation.add(activation)
        }
        if let activation = result.emg2ActivationPercent {
            catCow.emg2Activation.add(activation)
        }

        let upperCompletion = Self.clamp(
            result.upperRange / YORIPoseEngineThresholds.catCowMinimumUpperRange
        )
        let wholeCompletion = Self.clamp(
            result.wholeRange / YORIPoseEngineThresholds.catCowMinimumWholeRange
        )
        catCow.rangeScoreTotal += (upperCompletion + wholeCompletion) * 50

        session.catCow = catCow
        self.session = session
    }

    func ingestPressure(_ result: YORIPressureResult) {
        guard var session, session.activeStartedAt != nil else { return }

        switch (session.pose, result.source) {
        case (.mountain, .mountainFeet):
            session.mountain.pressureSymmetry.add(Self.clampScore(result.symmetry))
        case (.catCow, .catCowHands):
            session.catCow.pressureSymmetry.add(Self.clampScore(result.symmetry))
        default:
            return
        }

        self.session = session
    }

    func finishSession() -> YORISessionResult? {
        pauseSession()
        guard let session else { return nil }
        self.session = nil

        let result: YORISessionResult?
        switch session.pose {
        case .mountain:
            result = mountainResult(from: session)
        case .catCow:
            result = catCowResult(from: session)
        }

        #if DEBUG
        if let result {
            Self.log(result)
        } else {
            print("[YORI Session Result] insufficient valid active-session data")
        }
        #endif

        return result
    }

    private func mountainResult(from session: ActiveSession) -> YORISessionResult? {
        let mountain = session.mountain
        guard
            session.accumulatedDuration >= YORISessionScoringConstants.minimumMountainDurationSeconds,
            mountain.sampleCount >= YORISessionScoringConstants.minimumMountainSamples,
            mountain.gyroSampleCount >= YORISessionScoringConstants.minimumMountainGyroSamples
        else {
            return nil
        }

        let sampleCount = Double(mountain.sampleCount)
        let correctRatio = Double(mountain.stateCounts[.correct, default: 0]) / sampleCount
        let roundedRatio = Double(mountain.stateCounts[.roundedUpperBack, default: 0]) / sampleCount
        let anteriorRatio = Double(mountain.stateCounts[.anteriorPelvicTilt, default: 0]) / sampleCount
        let posteriorRatio = Double(mountain.stateCounts[.posteriorPelvicTilt, default: 0]) / sampleCount

        let classificationScore = correctRatio * 100
        let continuousScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainContinuousDeviationPenalty
                * mountain.severityTotal / sampleCount
        )
        let rawAlignmentScore = Self.clampScore(
            YORISessionScoringConstants.mountainAlignmentClassificationWeight
                * classificationScore
                + YORISessionScoringConstants.mountainAlignmentContinuousWeight
                * continuousScore
        )

        let orientationVariability = Self.mean(
            mountain.orientations.map(\.populationStandardDeviation)
        )
        let relativeAngleVariability = Self.mean([
            mountain.upperPitch.populationStandardDeviation,
            mountain.lowerPitch.populationStandardDeviation,
            mountain.upperRoll.populationStandardDeviation,
            mountain.lowerRoll.populationStandardDeviation
        ])
        let orientationDrift = Self.mean(
            zip(mountain.firstOrientation ?? [], mountain.lastOrientation ?? [])
                .map { abs($0 - $1) }
        )
        let orientationScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainOrientationVariabilityPenalty
                * orientationVariability
        )
        let relativeScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainRelativeAngleVariabilityPenalty
                * relativeAngleVariability
        )
        let driftScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainOrientationDriftPenalty
                * orientationDrift
        )
        let flexStability = YORISessionScoringConstants.mountainStabilityOrientationWeight
            * orientationScore
            + YORISessionScoringConstants.mountainStabilityRelativeAngleWeight
            * relativeScore
            + YORISessionScoringConstants.mountainStabilityDriftWeight
            * driftScore
        let footSymmetry = mountain.pressureSymmetry.count > 0
            ? mountain.pressureSymmetry.mean
            : nil
        let rawStabilityScore = Self.clampScore(
            footSymmetry.map {
                YORISessionScoringConstants.flexOnlyWeightWithPressure * flexStability
                    + YORISessionScoringConstants.optionalPressureWeight * $0
            } ?? flexStability
        )

        let gyroRMS = sqrt(mountain.gyroSquaredTotal / Double(mountain.gyroSampleCount))
        let durationMinutes = max(session.accumulatedDuration / 60, 1.0 / 60)
        let correctionsPerMinute = Double(mountain.excessiveCorrectionCount) / durationMinutes
        let switchesPerMinute = Double(mountain.stateSwitchCount) / durationMinutes
        let gyroRMSScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainGyroRMSPenalty * gyroRMS
        )
        let gyroPeakScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainGyroPeakPenalty * mountain.gyroPeak
        )
        let correctionScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainCorrectionRatePenalty
                * correctionsPerMinute
        )
        let switchingScore = Self.clampScore(
            100 - YORISessionScoringConstants.mountainStateSwitchRatePenalty
                * switchesPerMinute
        )
        let rawControlScore = Self.clampScore(
            YORISessionScoringConstants.mountainControlGyroRMSWeight * gyroRMSScore
                + YORISessionScoringConstants.mountainControlGyroPeakWeight
                * gyroPeakScore
                + YORISessionScoringConstants.mountainControlCorrectionWeight
                * correctionScore
                + YORISessionScoringConstants.mountainControlStateSwitchWeight
                * switchingScore
        )

        let metrics = YORIMountainSessionMetrics(
            sampleCount: mountain.sampleCount,
            correctTimeRatio: correctRatio,
            roundedTimeRatio: roundedRatio,
            anteriorTiltTimeRatio: anteriorRatio,
            posteriorTiltTimeRatio: posteriorRatio,
            meanUpperSpinePitch: mountain.upperPitch.mean,
            meanLowerSpinePitch: mountain.lowerPitch.mean,
            relativeAngleVariability: relativeAngleVariability,
            orientationVariability: orientationVariability,
            orientationDrift: orientationDrift,
            gyroRMS: gyroRMS,
            gyroPeak: mountain.gyroPeak,
            excessiveCorrectionCount: mountain.excessiveCorrectionCount,
            stateSwitchCount: mountain.stateSwitchCount,
            footPressureSymmetry: footSymmetry,
            emg1ActivationPercent: nil,
            emg2ActivationPercent: nil
        )
        let rawScores = YORISessionDimensionScores(
            alignment: rawAlignmentScore,
            stability: rawStabilityScore,
            control: rawControlScore
        )
        let finalScores = YORIScoreCalibrator.calibrate(rawScores)
        let overallScore = Self.clampScore(
            (finalScores.alignment + finalScores.stability + finalScores.control) / 3
        )

        return YORISessionResult(
            pose: .mountain,
            durationSeconds: session.accumulatedDuration,
            rawScores: rawScores,
            alignmentScore: finalScores.alignment,
            stabilityScore: finalScores.stability,
            controlScore: finalScores.control,
            overallScore: overallScore,
            mainFeedback: mountainFeedback(
                alignment: rawAlignmentScore,
                stability: rawStabilityScore,
                control: rawControlScore,
                metrics: metrics
            ),
            mountainMetrics: metrics,
            catCowMetrics: nil
        )
    }

    private func catCowResult(from session: ActiveSession) -> YORISessionResult? {
        let catCow = session.catCow
        let evaluationSpan = max(
            0,
            (catCow.lastEvaluationTimestamp ?? 0) - (catCow.firstEvaluationTimestamp ?? 0)
        )
        guard
            catCow.validEvaluationWindowCount
                >= YORISessionScoringConstants.minimumCatCowEvaluationWindows,
            evaluationSpan >= YORISessionScoringConstants.minimumCatCowEvaluationSpanSeconds
        else {
            return nil
        }

        let windowCount = Double(catCow.validEvaluationWindowCount)
        let incompleteRangeRatio = Double(catCow.incompleteRangeCount) / windowCount
        let poorControlRatio = Double(catCow.poorControlCount) / windowCount
        let meanRangeScore = catCow.rangeScoreTotal / windowCount
        let rangeIssueScore = (1 - incompleteRangeRatio) * 100
        let rawAlignmentScore = Self.clampScore(
            YORISessionScoringConstants.catCowAlignmentRangeWeight * meanRangeScore
                + YORISessionScoringConstants.catCowAlignmentIssueWeight * rangeIssueScore
        )

        let meanGyroRMS = catCow.gyroRMS.mean
        let robustGyroPeak = Self.percentile(
            catCow.gyroPeakValues,
            percentile: YORISessionScoringConstants.catCowRobustPeakPercentile
        )
        let rmsQualityScore = Self.catCowRMSQualityScore(for: meanGyroRMS)
        let peakQualityScore = Self.catCowPeakQualityScore(for: robustGyroPeak)
        let temporalControlScore = Self.clampScore((1 - poorControlRatio) * 100)
        let rawControlScore = Self.clampScore(
            YORISessionScoringConstants.catCowControlRMSQualityWeight * rmsQualityScore
                + YORISessionScoringConstants.catCowControlPeakQualityWeight
                * peakQualityScore
                + YORISessionScoringConstants.catCowControlTemporalWeight
                * temporalControlScore
        )

        let upperRangeVariability = catCow.upperRange.populationStandardDeviation
        let wholeRangeVariability = catCow.wholeRange.populationStandardDeviation
        let upperConsistency = Self.clampScore(
            100 - 100 / YORISessionScoringConstants.catCowUpperRangeVariabilityLimit
                * upperRangeVariability
        )
        let wholeConsistency = Self.clampScore(
            100 - 100 / YORISessionScoringConstants.catCowWholeRangeVariabilityLimit
                * wholeRangeVariability
        )
        let gyroConsistency = Self.clampScore(
            100 - 100 / YORIPoseEngineThresholds.catCowMaximumGyroRMS
                * catCow.gyroRMS.populationStandardDeviation
        )
        let movementConsistency = YORISessionScoringConstants.catCowStabilityUpperRangeWeight
            * upperConsistency
            + YORISessionScoringConstants.catCowStabilityWholeRangeWeight
            * wholeConsistency
            + YORISessionScoringConstants.catCowStabilityGyroWeight
            * gyroConsistency
        let handSymmetry = catCow.pressureSymmetry.count > 0
            ? catCow.pressureSymmetry.mean
            : nil
        let rawStabilityScore = Self.clampScore(
            handSymmetry.map {
                YORISessionScoringConstants.flexOnlyWeightWithPressure * movementConsistency
                    + YORISessionScoringConstants.optionalPressureWeight * $0
            }
                ?? movementConsistency
        )

        let metrics = YORICatCowSessionMetrics(
            validEvaluationWindowCount: catCow.validEvaluationWindowCount,
            incompleteRangeRatio: incompleteRangeRatio,
            poorControlRatio: poorControlRatio,
            meanUpperRange: catCow.upperRange.mean,
            meanLowerRange: catCow.lowerRange.mean,
            meanWholeRange: catCow.wholeRange.mean,
            upperRangeVariability: upperRangeVariability,
            wholeRangeVariability: wholeRangeVariability,
            meanGyroRMS: meanGyroRMS,
            meanGyroPeak: catCow.gyroPeak.mean,
            robustGyroPeak: robustGyroPeak,
            rmsQualityScore: rmsQualityScore,
            peakQualityScore: peakQualityScore,
            temporalControlScore: temporalControlScore,
            gyroConsistency: gyroConsistency,
            handPressureSymmetry: handSymmetry,
            emg1ActivationPercent: catCow.emg1Activation.count > 0
                ? catCow.emg1Activation.mean
                : nil,
            emg2ActivationPercent: catCow.emg2Activation.count > 0
                ? catCow.emg2Activation.mean
                : nil
        )
        let rawScores = YORISessionDimensionScores(
            alignment: rawAlignmentScore,
            stability: rawStabilityScore,
            control: rawControlScore
        )
        let finalScores = YORIScoreCalibrator.calibrate(rawScores)
        let overallScore = Self.clampScore(
            (finalScores.alignment + finalScores.stability + finalScores.control) / 3
        )

        return YORISessionResult(
            pose: .catCow,
            durationSeconds: session.accumulatedDuration,
            rawScores: rawScores,
            alignmentScore: finalScores.alignment,
            stabilityScore: finalScores.stability,
            controlScore: finalScores.control,
            overallScore: overallScore,
            mainFeedback: catCowFeedback(
                alignment: rawAlignmentScore,
                stability: rawStabilityScore,
                control: rawControlScore
            ),
            mountainMetrics: nil,
            catCowMetrics: metrics
        )
    }

    private func mountainFeedback(
        alignment: Double,
        stability: Double,
        control: Double,
        metrics: YORIMountainSessionMetrics
    ) -> String {
        if min(alignment, stability, control)
            >= YORISessionScoringConstants.strongPerformanceScore {
            return "Great work - your alignment was steady and controlled."
        }
        if alignment <= stability, alignment <= control {
            if metrics.roundedTimeRatio >= metrics.anteriorTiltTimeRatio,
               metrics.roundedTimeRatio >= metrics.posteriorTiltTimeRatio {
                return "Your upper back rounded during part of the hold. Try lengthening gently through your upper spine."
            }
            return "Keep your pelvis closer to neutral during the hold."
        }
        if stability <= control {
            return "Try to reduce small body shifts and hold the posture more steadily."
        }
        return "Make posture corrections more slowly and smoothly."
    }

    private func catCowFeedback(
        alignment: Double,
        stability: Double,
        control: Double
    ) -> String {
        if min(alignment, stability, control)
            >= YORISessionScoringConstants.strongPerformanceScore {
            return "Great work - your movement was balanced and controlled."
        }
        if alignment <= stability, alignment <= control {
            return "Move through a fuller spinal range."
        }
        if stability <= control {
            return "Try to keep each Cat-Cow cycle more consistent."
        }
        return "Slow the transition and move more smoothly."
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clampScore(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func catCowRMSQualityScore(for value: Double) -> Double {
        let constants = YORISessionScoringConstants.self
        switch value {
        case ...constants.catCowRMSFullQualityMaximum:
            return 100
        case ...constants.catCowRMSPoorControlBoundary:
            return interpolate(
                value,
                from: constants.catCowRMSFullQualityMaximum,
                through: constants.catCowRMSPoorControlBoundary,
                startScore: 100,
                endScore: 80
            )
        case ...constants.catCowRMSModerateMaximum:
            return interpolate(
                value,
                from: constants.catCowRMSPoorControlBoundary,
                through: constants.catCowRMSModerateMaximum,
                startScore: 80,
                endScore: 50
            )
        case ...constants.catCowRMSLowMaximum:
            return interpolate(
                value,
                from: constants.catCowRMSModerateMaximum,
                through: constants.catCowRMSLowMaximum,
                startScore: 50,
                endScore: 20
            )
        default:
            return interpolate(
                value,
                from: constants.catCowRMSLowMaximum,
                through: constants.catCowRMSZeroQuality,
                startScore: 20,
                endScore: 0
            )
        }
    }

    private static func catCowPeakQualityScore(for value: Double) -> Double {
        let constants = YORISessionScoringConstants.self
        switch value {
        case ...constants.catCowPeakFullQualityMaximum:
            return 100
        case ...constants.catCowPeakGoodMaximum:
            return interpolate(
                value,
                from: constants.catCowPeakFullQualityMaximum,
                through: constants.catCowPeakGoodMaximum,
                startScore: 100,
                endScore: 80
            )
        case ...constants.catCowPeakModerateMaximum:
            return interpolate(
                value,
                from: constants.catCowPeakGoodMaximum,
                through: constants.catCowPeakModerateMaximum,
                startScore: 80,
                endScore: 50
            )
        case ...constants.catCowPeakLowMaximum:
            return interpolate(
                value,
                from: constants.catCowPeakModerateMaximum,
                through: constants.catCowPeakLowMaximum,
                startScore: 50,
                endScore: 20
            )
        default:
            return interpolate(
                value,
                from: constants.catCowPeakLowMaximum,
                through: constants.catCowPeakZeroQuality,
                startScore: 20,
                endScore: 0
            )
        }
    }

    private static func interpolate(
        _ value: Double,
        from lowerValue: Double,
        through upperValue: Double,
        startScore: Double,
        endScore: Double
    ) -> Double {
        let progress = clamp((value - lowerValue) / (upperValue - lowerValue))
        return clampScore(startScore + progress * (endScore - startScore))
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sortedValues = values.sorted()
        let rank = clamp(percentile) * Double(sortedValues.count - 1)
        let lowerIndex = Int(floor(rank))
        let upperIndex = Int(ceil(rank))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let fraction = rank - Double(lowerIndex)
        return sortedValues[lowerIndex]
            + fraction * (sortedValues[upperIndex] - sortedValues[lowerIndex])
    }

    #if DEBUG
    private static func log(_ result: YORISessionResult) {
        var lines = [
            "[YORI Session Result]",
            "Pose: \(result.pose.displayName)",
            "Duration: \(formatted(result.durationSeconds)) s",
            "Final Alignment: \(formatted(result.alignmentScore))",
            "Final Stability: \(formatted(result.stabilityScore))",
            "Final Control: \(formatted(result.controlScore))",
            "Final Overall: \(formatted(result.overallScore))",
            "",
            "[YORI Score Calibration]",
            "Pose: \(result.pose.displayName)",
            "Raw Alignment: \(formatted(result.rawScores.alignment))",
            "Final Alignment: \(formatted(result.alignmentScore))",
            "Raw Stability: \(formatted(result.rawScores.stability))",
            "Final Stability: \(formatted(result.stabilityScore))",
            "Raw Control: \(formatted(result.rawScores.control))",
            "Final Control: \(formatted(result.controlScore))",
            "Final Overall: \(formatted(result.overallScore))",
            "",
            "Supporting metrics:"
        ]

        if let metrics = result.mountainMetrics {
            lines.append("Correct ratio: \(formatted(metrics.correctTimeRatio))")
            lines.append("Rounded ratio: \(formatted(metrics.roundedTimeRatio))")
            lines.append("Anterior ratio: \(formatted(metrics.anteriorTiltTimeRatio))")
            lines.append("Posterior ratio: \(formatted(metrics.posteriorTiltTimeRatio))")
            lines.append("Mean upper pitch: \(formatted(metrics.meanUpperSpinePitch))")
            lines.append("Mean lower pitch: \(formatted(metrics.meanLowerSpinePitch))")
            lines.append("Orientation variability: \(formatted(metrics.orientationVariability))")
            lines.append("Relative-angle variability: \(formatted(metrics.relativeAngleVariability))")
            lines.append("Gyro RMS: \(formatted(metrics.gyroRMS))")
            lines.append("Gyro peak: \(formatted(metrics.gyroPeak))")
            lines.append("Foot symmetry: \(formatted(metrics.footPressureSymmetry))")
        } else if let metrics = result.catCowMetrics {
            lines.append("Valid windows: \(metrics.validEvaluationWindowCount)")
            lines.append("Incomplete range ratio: \(formatted(metrics.incompleteRangeRatio))")
            lines.append("Poor control ratio: \(formatted(metrics.poorControlRatio))")
            lines.append("Mean upper range: \(formatted(metrics.meanUpperRange))")
            lines.append("Mean whole range: \(formatted(metrics.meanWholeRange))")
            lines.append("Mean gyro RMS: \(formatted(metrics.meanGyroRMS))")
            lines.append("P90 gyro peak: \(formatted(metrics.robustGyroPeak))")
            lines.append("Upper-range variability: \(formatted(metrics.upperRangeVariability))")
            lines.append("Whole-range variability: \(formatted(metrics.wholeRangeVariability))")
            lines.append("Hand symmetry: \(formatted(metrics.handPressureSymmetry))")
            lines.append("")
            lines.append("[YORI CatCow Control]")
            lines.append("Mean gyro RMS: \(formatted(metrics.meanGyroRMS))")
            lines.append("P90 gyro peak: \(formatted(metrics.robustGyroPeak))")
            lines.append("Poor-control ratio: \(formatted(metrics.poorControlRatio))")
            lines.append("RMS quality: \(formatted(metrics.rmsQualityScore))")
            lines.append("Peak quality: \(formatted(metrics.peakQualityScore))")
            lines.append("Temporal quality: \(formatted(metrics.temporalControlScore))")
            lines.append("Raw control: \(formatted(result.rawScores.control))")
        }

        print(lines.joined(separator: "\n"))
    }

    private static func formatted(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "%.2f", value)
    }
    #endif
}
