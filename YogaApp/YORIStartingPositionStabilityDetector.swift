import Foundation

struct YORIStartingPositionStabilityResult: Equatable {
    let isStable: Bool
    let sampleCount: Int
    let rollingWindowDuration: TimeInterval
    let maximumAngleStandardDeviation: Double
    let maximumAngleDrift: Double
    let gyroMovementMetric: Double?
    let latestSampleTimestamp: TimeInterval?
    let timeUntilStableDetection: TimeInterval?
    let emg1Median: Double?
    let emg2Median: Double?

    static let empty = YORIStartingPositionStabilityResult(
        isStable: false,
        sampleCount: 0,
        rollingWindowDuration: 0,
        maximumAngleStandardDeviation: 0,
        maximumAngleDrift: 0,
        gyroMovementMetric: nil,
        latestSampleTimestamp: nil,
        timeUntilStableDetection: nil,
        emg1Median: nil,
        emg2Median: nil
    )

    func sampleAge(at timestamp: TimeInterval) -> TimeInterval? {
        guard let latestSampleTimestamp else { return nil }
        return max(0, timestamp - latestSampleTimestamp)
    }
}

struct YORIStartingPositionStabilityDetector {
    private(set) var diagnostics = YORIStartingPositionStabilityResult.empty
    private var samples: [YORIFlexMainSensorSample] = []
    private var firstObservedTimestamp: TimeInterval?
    private var stableDetectionElapsedTime: TimeInterval?

    mutating func reset() {
        samples.removeAll()
        firstObservedTimestamp = nil
        stableDetectionElapsedTime = nil
        diagnostics = .empty
    }

    mutating func ingest(
        _ sample: YORIFlexMainSensorSample
    ) -> YORIStartingPositionStabilityResult {
        if let lastTimestamp = samples.last?.timestamp,
           sample.timestamp <= lastTimestamp {
            samples.removeAll()
            firstObservedTimestamp = nil
            stableDetectionElapsedTime = nil
        }

        firstObservedTimestamp = firstObservedTimestamp ?? sample.timestamp
        samples.append(sample)
        trimWindow(endingAt: sample.timestamp)

        let angleSeries = [
            samples.map(\.t3Roll),
            samples.map(\.t3Pitch),
            samples.map(\.t12Roll),
            samples.map(\.t12Pitch),
            samples.map(\.s1Roll),
            samples.map(\.s1Pitch)
        ]
        let maximumStandardDeviation = angleSeries.map(standardDeviation).max() ?? 0
        let maximumDrift = angleSeries.map(drift).max() ?? 0
        let rollingWindowDuration = max(
            0,
            (samples.last?.timestamp ?? sample.timestamp)
                - (samples.first?.timestamp ?? sample.timestamp)
        )

        // Development movement-stability thresholds only. They detect a short period
        // of low IMU movement and are not medical, clinical, or pose-correctness rules.
        let isStable = hasEnoughData
            && maximumStandardDeviation
            <= YORIStartingPositionStabilityThresholds.maximumAngleStandardDeviation
            && maximumDrift <= YORIStartingPositionStabilityThresholds.maximumAngleDrift

        if isStable, stableDetectionElapsedTime == nil, let firstObservedTimestamp {
            stableDetectionElapsedTime = max(0, sample.timestamp - firstObservedTimestamp)
        }

        diagnostics = YORIStartingPositionStabilityResult(
            isStable: isStable,
            sampleCount: samples.count,
            rollingWindowDuration: rollingWindowDuration,
            maximumAngleStandardDeviation: maximumStandardDeviation,
            maximumAngleDrift: maximumDrift,
            // Starting-position stability currently uses orientation only.
            gyroMovementMetric: nil,
            latestSampleTimestamp: sample.timestamp,
            timeUntilStableDetection: stableDetectionElapsedTime,
            emg1Median: isStable ? median(samples.map(\.emg1)) : nil,
            emg2Median: isStable ? median(samples.map(\.emg2)) : nil
        )
        return diagnostics
    }

    private var hasEnoughData: Bool {
        guard
            samples.count >= YORIStartingPositionStabilityThresholds.minimumSampleCount,
            let firstTimestamp = samples.first?.timestamp,
            let lastTimestamp = samples.last?.timestamp
        else {
            return false
        }

        return lastTimestamp - firstTimestamp
            >= YORIStartingPositionStabilityThresholds.minimumObservedDurationSeconds
    }

    private mutating func trimWindow(endingAt timestamp: TimeInterval) {
        let earliestTimestamp = timestamp
            - YORIStartingPositionStabilityThresholds.windowDurationSeconds
        samples.removeAll { $0.timestamp < earliestTimestamp }
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values
            .map { value in
                let difference = value - mean
                return difference * difference
            }
            .reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }

    private func drift(_ values: [Double]) -> Double {
        guard let first = values.first, let last = values.last else { return 0 }
        return abs(last - first)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let middle = sortedValues.count / 2

        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }

        return sortedValues[middle]
    }
}

enum YORIStartingPositionStabilityThresholds {
    static let windowDurationSeconds: TimeInterval = 1.5
    static let minimumObservedDurationSeconds: TimeInterval = 1.05
    static let minimumSampleCount = 8

    // Development movement-stability thresholds only. They are not final pediatric
    // clinical thresholds and do not determine whether either pose is correct.
    static let maximumAngleStandardDeviation = 1.0
    static let maximumAngleDrift = 1.875

    // Development hardware-settle delay after the firmware accepts CAL.
    static let calibrationSettleDelayNanoseconds: UInt64 = 800_000_000
}

#if DEBUG
enum YORIStartingPositionStabilityDevelopmentExamples {
    static func stableWindow() -> YORIStartingPositionStabilityResult {
        var detector = YORIStartingPositionStabilityDetector()
        var result = detector.ingest(sample(timestamp: 0, offset: 0))

        for index in 1...8 {
            result = detector.ingest(
                sample(
                    timestamp: Double(index) * 0.2,
                    offset: index.isMultiple(of: 2) ? 0.1 : -0.1
                )
            )
        }

        return result
    }

    private static func sample(
        timestamp: TimeInterval,
        offset: Double
    ) -> YORIFlexMainSensorSample {
        YORIFlexMainSensorSample(
            sequence: UInt16(timestamp * 10),
            timestamp: timestamp,
            t3Roll: offset,
            t3Pitch: offset,
            t12Roll: offset,
            t12Pitch: offset,
            s1Roll: offset,
            s1Pitch: offset,
            emg1: 100 + offset,
            emg2: 110 + offset
        )
    }
}
#endif
