import Foundation

struct YORIPoseEngine {
    var emg1Baseline: Double?
    var emg2Baseline: Double?
    var catCowWindowDurationSeconds: TimeInterval

    private var catCowFrames: [YORICatCowFrame] = []

    init(
        emg1Baseline: Double? = nil,
        emg2Baseline: Double? = nil,
        catCowWindowDurationSeconds: TimeInterval = YORIPoseEngineThresholds.catCowWindowDurationSeconds
    ) {
        self.emg1Baseline = emg1Baseline
        self.emg2Baseline = emg2Baseline
        self.catCowWindowDurationSeconds = catCowWindowDurationSeconds
    }

    mutating func setEMGBaseline(emg1: Double, emg2: Double) {
        emg1Baseline = emg1
        emg2Baseline = emg2
    }

    mutating func clearEMGBaseline() {
        emg1Baseline = nil
        emg2Baseline = nil
    }

    mutating func resetCatCowWindow() {
        catCowFrames.removeAll()
    }

    func evaluateMountain(_ input: YORIMountainInput) -> YORIMountainResult {
        let features = YORISpineFeatures(
            t3Roll: input.t3Roll,
            t3Pitch: input.t3Pitch,
            t12Roll: input.t12Roll,
            t12Pitch: input.t12Pitch,
            s1Roll: input.s1Roll,
            s1Pitch: input.s1Pitch
        )

        let state: YORIMountainState

        // Prototype adult-development thresholds only. These are not final pediatric
        // clinical thresholds and must be replaced only after validated review.
        if features.lowerSpinePitch <= YORIPoseEngineThresholds.mountainPosteriorPelvicTiltLowerPitchMaximum
            && features.upperSpinePitch >= YORIPoseEngineThresholds.mountainPosteriorPelvicTiltUpperPitchMinimum {
            state = .posteriorPelvicTilt
        } else if features.lowerSpinePitch >= YORIPoseEngineThresholds.mountainAnteriorPelvicTiltLowerPitchMinimum {
            state = .anteriorPelvicTilt
        } else if features.upperSpinePitch >= YORIPoseEngineThresholds.mountainRoundedUpperBackPitchMinimum {
            state = .roundedUpperBack
        } else {
            state = .correct
        }

        return YORIMountainResult(
            state: state,
            upperSpinePitch: features.upperSpinePitch,
            lowerSpinePitch: features.lowerSpinePitch,
            upperSpineRoll: features.upperSpineRoll,
            lowerSpineRoll: features.lowerSpineRoll
        )
    }

    mutating func ingestCatCowFrame(_ frame: YORICatCowFrame) -> YORICatCowResult {
        catCowFrames.append(frame)
        trimCatCowWindow(endingAt: frame.timestamp)

        return evaluateCatCowWindow(catCowFrames)
    }

    func evaluateCatCowWindow(_ frames: [YORICatCowFrame]) -> YORICatCowResult {
        let orderedFrames = frames.sorted { $0.timestamp < $1.timestamp }
        guard !orderedFrames.isEmpty else {
            return YORICatCowResult.empty(hasEnoughDataForEvaluation: false)
        }

        let upperSpineValues = orderedFrames.map { $0.t3Pitch - $0.t12Pitch }
        let lowerSpineValues = orderedFrames.map { $0.t12Pitch - $0.s1Pitch }
        let wholeSpineValues = orderedFrames.map { $0.t3Pitch - $0.s1Pitch }
        let combinedGyroValues = orderedFrames.map { $0.combinedGyroMagnitude }

        let upperRange = range(of: upperSpineValues)
        let lowerRange = range(of: lowerSpineValues)
        let wholeRange = range(of: wholeSpineValues)
        let gyroRMS = rootMeanSquare(of: combinedGyroValues)
        let gyroPeak = combinedGyroValues.max() ?? 0
        let windowDuration = max(
            0,
            (orderedFrames.last?.timestamp ?? 0) - (orderedFrames.first?.timestamp ?? 0)
        )
        let frameCount = orderedFrames.count
        let emg1Activation = normalizedActivationPercent(
            currentMean: mean(of: orderedFrames.map(\.emg1)),
            baseline: emg1Baseline
        )
        let emg2Activation = normalizedActivationPercent(
            currentMean: mean(of: orderedFrames.map(\.emg2)),
            baseline: emg2Baseline
        )
        let enoughData = hasEnoughCatCowData(orderedFrames)

        guard enoughData else {
            return YORICatCowResult(
                issues: [],
                windowDuration: windowDuration,
                frameCount: frameCount,
                upperRange: upperRange,
                lowerRange: lowerRange,
                wholeRange: wholeRange,
                gyroRMS: gyroRMS,
                gyroPeak: gyroPeak,
                emg1ActivationPercent: emg1Activation,
                emg2ActivationPercent: emg2Activation,
                hasEnoughDataForEvaluation: false
            )
        }

        var issues: [YORICatCowIssue] = []

        // Prototype adult-development thresholds only. These are not final pediatric
        // clinical thresholds and must be replaced only after validated review.
        if upperRange < YORIPoseEngineThresholds.catCowMinimumUpperRange
            || wholeRange < YORIPoseEngineThresholds.catCowMinimumWholeRange {
            issues.append(.incompleteRange)
        }

        if gyroRMS > YORIPoseEngineThresholds.catCowMaximumGyroRMS {
            issues.append(.poorControl)
        }

        return YORICatCowResult(
            issues: issues,
            windowDuration: windowDuration,
            frameCount: frameCount,
            upperRange: upperRange,
            lowerRange: lowerRange,
            wholeRange: wholeRange,
            gyroRMS: gyroRMS,
            gyroPeak: gyroPeak,
            emg1ActivationPercent: emg1Activation,
            emg2ActivationPercent: emg2Activation,
            hasEnoughDataForEvaluation: true
        )
    }

    func evaluateMountainPressure(leftFoot: Double, rightFoot: Double) -> YORIPressureResult {
        pressureDistribution(source: .mountainFeet, left: leftFoot, right: rightFoot)
    }

    func evaluateCatCowPressure(leftHand: Double, rightHand: Double) -> YORIPressureResult {
        pressureDistribution(source: .catCowHands, left: leftHand, right: rightHand)
    }

    func pressureDistribution(
        source: YORIPressureSource,
        left: Double,
        right: Double
    ) -> YORIPressureResult {
        let total = left + right

        guard total > 0 else {
            return YORIPressureResult(
                source: source,
                leftPercent: 0,
                rightPercent: 0,
                symmetry: 0
            )
        }

        let leftPercent = left / total * 100
        let rightPercent = right / total * 100

        return YORIPressureResult(
            source: source,
            leftPercent: leftPercent,
            rightPercent: rightPercent,
            symmetry: 100 - abs(leftPercent - rightPercent)
        )
    }

    private mutating func trimCatCowWindow(endingAt timestamp: TimeInterval) {
        let earliestTimestamp = timestamp - catCowWindowDurationSeconds
        guard let firstIndexInsideWindow = catCowFrames.firstIndex(where: {
            $0.timestamp >= earliestTimestamp
        }) else {
            return
        }

        // Retain the sample immediately before the cutoff so the rolling window
        // actually spans the configured duration between discrete sensor frames.
        let firstIndexToKeep = max(0, firstIndexInsideWindow - 1)
        if firstIndexToKeep > 0 {
            catCowFrames.removeFirst(firstIndexToKeep)
        }
    }

    private func hasEnoughCatCowData(_ frames: [YORICatCowFrame]) -> Bool {
        guard
            let firstTimestamp = frames.first?.timestamp,
            let lastTimestamp = frames.last?.timestamp
        else {
            return false
        }

        return frames.count >= 2
            && lastTimestamp - firstTimestamp >= catCowWindowDurationSeconds
    }

    private func range(of values: [Double]) -> Double {
        guard
            let minimum = values.min(),
            let maximum = values.max()
        else {
            return 0
        }

        return maximum - minimum
    }

    private func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func rootMeanSquare(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let meanSquare = values.map { $0 * $0 }.reduce(0, +) / Double(values.count)
        return sqrt(meanSquare)
    }

    private func normalizedActivationPercent(currentMean: Double, baseline: Double?) -> Double? {
        guard let baseline else { return nil }
        let denominator = max(abs(baseline), 1)
        return (currentMean - baseline) / denominator * 100
    }
}

enum YORIMountainState: Equatable, Hashable {
    case correct
    case roundedUpperBack
    case anteriorPelvicTilt
    case posteriorPelvicTilt
}

struct YORIMountainInput: Equatable {
    let t3Roll: Double
    let t3Pitch: Double
    let t12Roll: Double
    let t12Pitch: Double
    let s1Roll: Double
    let s1Pitch: Double
}

struct YORIMountainResult: Equatable {
    let state: YORIMountainState
    let upperSpinePitch: Double
    let lowerSpinePitch: Double
    let upperSpineRoll: Double
    let lowerSpineRoll: Double
}

enum YORICatCowIssue: Equatable, Hashable {
    case incompleteRange
    case poorControl
}

struct YORICatCowFrame: Equatable {
    let timestamp: TimeInterval
    let t3Pitch: Double
    let t12Pitch: Double
    let s1Pitch: Double
    let t3Gyro: YORIGyroSample
    let t12Gyro: YORIGyroSample
    let s1Gyro: YORIGyroSample
    let emg1: Double
    let emg2: Double

    var combinedGyroMagnitude: Double {
        sqrt(
            t3Gyro.magnitude * t3Gyro.magnitude
                + t12Gyro.magnitude * t12Gyro.magnitude
                + s1Gyro.magnitude * s1Gyro.magnitude
        )
    }
}

struct YORIGyroSample: Equatable {
    let x: Double
    let y: Double
    let z: Double

    var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }
}

struct YORICatCowResult: Equatable {
    let issues: [YORICatCowIssue]
    let windowDuration: TimeInterval
    let frameCount: Int
    let upperRange: Double
    let lowerRange: Double
    let wholeRange: Double
    let gyroRMS: Double
    let gyroPeak: Double
    let emg1ActivationPercent: Double?
    let emg2ActivationPercent: Double?
    let hasEnoughDataForEvaluation: Bool

    var isGood: Bool {
        hasEnoughDataForEvaluation && issues.isEmpty
    }

    static func empty(hasEnoughDataForEvaluation: Bool) -> YORICatCowResult {
        YORICatCowResult(
            issues: [],
            windowDuration: 0,
            frameCount: 0,
            upperRange: 0,
            lowerRange: 0,
            wholeRange: 0,
            gyroRMS: 0,
            gyroPeak: 0,
            emg1ActivationPercent: nil,
            emg2ActivationPercent: nil,
            hasEnoughDataForEvaluation: hasEnoughDataForEvaluation
        )
    }
}

enum YORIPressureSource: Equatable {
    case mountainFeet
    case catCowHands
    case custom(String)
}

struct YORIPressureResult: Equatable {
    let source: YORIPressureSource
    let leftPercent: Double
    let rightPercent: Double
    let symmetry: Double
}

private struct YORISpineFeatures {
    let upperSpinePitch: Double
    let lowerSpinePitch: Double
    let upperSpineRoll: Double
    let lowerSpineRoll: Double

    init(
        t3Roll: Double,
        t3Pitch: Double,
        t12Roll: Double,
        t12Pitch: Double,
        s1Roll: Double,
        s1Pitch: Double
    ) {
        upperSpinePitch = t3Pitch - t12Pitch
        lowerSpinePitch = t12Pitch - s1Pitch
        upperSpineRoll = t3Roll - t12Roll
        lowerSpineRoll = t12Roll - s1Roll
    }
}

enum YORIPoseEngineThresholds {
    static let catCowWindowDurationSeconds: TimeInterval = 16

    // Prototype adult-development thresholds only. These are not final pediatric
    // clinical thresholds and must be replaced only after validated review.
    static let mountainRoundedUpperBackPitchMinimum = 2.5
    static let mountainAnteriorPelvicTiltLowerPitchMinimum = 4.5
    static let mountainPosteriorPelvicTiltLowerPitchMaximum = -10.0
    static let mountainPosteriorPelvicTiltUpperPitchMinimum = 10.0

    // Prototype adult-development thresholds only. These are not final pediatric
    // clinical thresholds and must be replaced only after validated review.
    static let catCowMinimumUpperRange = 24.0
    static let catCowMinimumWholeRange = 20.0
    static let catCowMaximumGyroRMS = 33.0
}

#if DEBUG
enum YORIPoseEngineDevelopmentExamples {
    static func mountainExamples() -> [YORIMountainResult] {
        let engine = YORIPoseEngine()

        return [
            engine.evaluateMountain(
                YORIMountainInput(
                    t3Roll: 0,
                    t3Pitch: 1,
                    t12Roll: 0,
                    t12Pitch: 0,
                    s1Roll: 0,
                    s1Pitch: 0
                )
            ),
            engine.evaluateMountain(
                YORIMountainInput(
                    t3Roll: 0,
                    t3Pitch: 3,
                    t12Roll: 0,
                    t12Pitch: 0,
                    s1Roll: 0,
                    s1Pitch: 0
                )
            ),
            engine.evaluateMountain(
                YORIMountainInput(
                    t3Roll: 0,
                    t3Pitch: 12,
                    t12Roll: 0,
                    t12Pitch: 0,
                    s1Roll: 0,
                    s1Pitch: 11
                )
            )
        ]
    }

    static func catCowBothIssuesExample() -> YORICatCowResult {
        let engine = YORIPoseEngine(emg1Baseline: 100, emg2Baseline: 100)
        let frames = [
            YORICatCowFrame(
                timestamp: 0,
                t3Pitch: 8,
                t12Pitch: 0,
                s1Pitch: -2,
                t3Gyro: YORIGyroSample(x: 30, y: 0, z: 0),
                t12Gyro: YORIGyroSample(x: 30, y: 0, z: 0),
                s1Gyro: YORIGyroSample(x: 30, y: 0, z: 0),
                emg1: 120,
                emg2: 130
            ),
            YORICatCowFrame(
                timestamp: 16,
                t3Pitch: 18,
                t12Pitch: 0,
                s1Pitch: -4,
                t3Gyro: YORIGyroSample(x: 30, y: 0, z: 0),
                t12Gyro: YORIGyroSample(x: 30, y: 0, z: 0),
                s1Gyro: YORIGyroSample(x: 30, y: 0, z: 0),
                emg1: 140,
                emg2: 150
            )
        ]

        return engine.evaluateCatCowWindow(frames)
    }
}
#endif
