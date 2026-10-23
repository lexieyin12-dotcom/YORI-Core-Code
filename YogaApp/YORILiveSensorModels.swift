import Foundation

struct YORIFlexMainSensorSample: Equatable {
    let sequence: UInt16
    let timestamp: TimeInterval
    let t3Roll: Double
    let t3Pitch: Double
    let t12Roll: Double
    let t12Pitch: Double
    let s1Roll: Double
    let s1Pitch: Double
    let emg1: Double
    let emg2: Double
}

struct YORIFlexGyroscopeSample: Equatable {
    let sequence: UInt16
    let timestamp: TimeInterval
    let t3: YORIGyroSample
    let t12: YORIGyroSample
    let s1: YORIGyroSample
}

struct YORIMatPressureSample: Equatable {
    let timestamp: TimeInterval
    let leftHand: Int
    let rightHand: Int
    let leftFoot: Int
    let rightFoot: Int
}

struct YORILiveSensorState: Equatable {
    var isFlexConnected = false
    var isFlexMainStreamFresh = false
    var isMatConnected = false
    var flexMain: YORIFlexMainSensorSample?
    var flexGyroscope: YORIFlexGyroscopeSample?
    var matPressure: YORIMatPressureSample?
}

enum YORILivePose: Equatable {
    case mountain
    case catCow

    var displayName: String {
        switch self {
        case .mountain: "Mountain"
        case .catCow: "Cat-Cow"
        }
    }
}

struct YORILiveMountainEvaluation: Equatable {
    let poseResult: YORIMountainResult
    let pressureResult: YORIPressureResult?
}

struct YORILiveCatCowEvaluation: Equatable {
    let poseResult: YORICatCowResult
    let pressureResult: YORIPressureResult?
}

enum YORILiveEvaluationResult: Equatable {
    case mountain(YORILiveMountainEvaluation)
    case catCow(YORILiveCatCowEvaluation)
}

#if DEBUG
struct YORICatCowLiveDiagnostics: Equatable {
    let isFlexConnected: Bool
    let mainSampleAge: TimeInterval?
    let gyroscopeSampleAge: TimeInterval?
    let windowDuration: TimeInterval
    let frameCount: Int
    let hasEnoughDataForEvaluation: Bool
    let upperRange: Double
    let lowerRange: Double
    let wholeRange: Double
    let gyroRMS: Double
    let gyroPeak: Double
    let issues: [YORICatCowIssue]
    let emg1ActivationPercent: Double?
    let emg2ActivationPercent: Double?
    let handPressureSymmetry: Double?

    static let empty = YORICatCowLiveDiagnostics(
        isFlexConnected: false,
        mainSampleAge: nil,
        gyroscopeSampleAge: nil,
        windowDuration: 0,
        frameCount: 0,
        hasEnoughDataForEvaluation: false,
        upperRange: 0,
        lowerRange: 0,
        wholeRange: 0,
        gyroRMS: 0,
        gyroPeak: 0,
        issues: [],
        emg1ActivationPercent: nil,
        emg2ActivationPercent: nil,
        handPressureSymmetry: nil
    )
}

enum YORILiveEvaluationDebugSnapshot: Equatable {
    case mountain(
        state: YORIMountainState,
        upperSpinePitch: Double,
        lowerSpinePitch: Double,
        pressureSymmetry: Double?
    )
    case catCow(
        enoughData: Bool,
        issues: [YORICatCowIssue],
        upperRange: Double,
        wholeRange: Double,
        gyroRMS: Double,
        emg1ActivationPercent: Double?,
        emg2ActivationPercent: Double?,
        pressureSymmetry: Double?
    )
}
#endif
