import Combine
import Foundation
import OSLog

@MainActor
final class YORILiveEvaluationManager: ObservableObject {
    @Published private(set) var currentPose: YORILivePose?
    @Published private(set) var sensorState = YORILiveSensorState()
    @Published private(set) var liveResult: YORILiveEvaluationResult?
    @Published private(set) var isEvaluationActive = false

    #if DEBUG
    @Published private(set) var debugSnapshot: YORILiveEvaluationDebugSnapshot?
    @Published private(set) var catCowDiagnostics = YORICatCowLiveDiagnostics.empty
    #endif

    private static let logger = Logger(
        subsystem: "com.lexieyin.yori",
        category: "YORILiveEvaluation"
    )

    private let matBLEManager: BLEManager
    private let flexBLEManager: YORIFlexBLEManager
    private var poseEngine: YORIPoseEngine
    private let sessionEvaluator: YORISessionEvaluator
    private var cancellables: Set<AnyCancellable> = []
    private var lastProcessedCatCowSequence: UInt16?
    private var catCowPausedAt: TimeInterval?
    private var catCowPausedDuration: TimeInterval = 0

    #if DEBUG
    private var lastDebugLogTimestamp: TimeInterval = 0
    private var catCowDiagnosticTask: Task<Void, Never>?
    #endif

    init(
        matBLEManager: BLEManager,
        flexBLEManager: YORIFlexBLEManager,
        poseEngine: YORIPoseEngine? = nil,
        sessionEvaluator: YORISessionEvaluator? = nil
    ) {
        self.matBLEManager = matBLEManager
        self.flexBLEManager = flexBLEManager
        self.poseEngine = poseEngine ?? YORIPoseEngine()
        self.sessionEvaluator = sessionEvaluator ?? YORISessionEvaluator()

        observeSensorSources()
    }

    func beginEvaluation(for pose: YORILivePose) {
        prepareEvaluation(for: pose)
        resumeEvaluation()
    }

    func prepareEvaluation(for pose: YORILivePose) {
        #if DEBUG
        stopCatCowDiagnosticMonitoring()
        catCowDiagnostics = .empty
        #endif

        currentPose = pose
        sessionEvaluator.cancelSession()
        isEvaluationActive = false
        liveResult = nil
        lastProcessedCatCowSequence = nil
        catCowPausedAt = nil
        catCowPausedDuration = 0
        poseEngine.resetCatCowWindow()

        #if DEBUG
        debugSnapshot = nil
        #endif
    }

    func pauseEvaluation() {
        if isEvaluationActive, currentPose == .catCow, catCowPausedAt == nil {
            catCowPausedAt = Date().timeIntervalSinceReferenceDate
        }
        isEvaluationActive = false

        #if DEBUG
        stopCatCowDiagnosticMonitoring()
        #endif
    }

    func resumeEvaluation() {
        guard let currentPose else { return }
        if currentPose == .catCow, let catCowPausedAt {
            catCowPausedDuration += max(
                0,
                Date().timeIntervalSinceReferenceDate - catCowPausedAt
            )
            self.catCowPausedAt = nil
        }
        isEvaluationActive = true

        switch currentPose {
        case .mountain:
            evaluateMountainIfPossible()
        case .catCow:
            evaluateCatCowIfPossible()

            #if DEBUG
            startCatCowDiagnosticMonitoring()
            #endif
        }
    }

    func stopEvaluation() {
        #if DEBUG
        stopCatCowDiagnosticMonitoring()
        catCowDiagnostics = .empty
        #endif

        currentPose = nil
        isEvaluationActive = false
        liveResult = nil
        lastProcessedCatCowSequence = nil
        catCowPausedAt = nil
        catCowPausedDuration = 0
        poseEngine.resetCatCowWindow()

        #if DEBUG
        debugSnapshot = nil
        #endif
    }

    func setEMGBaseline(emg1: Double, emg2: Double) {
        poseEngine.setEMGBaseline(emg1: emg1, emg2: emg2)
    }

    func clearEMGBaseline() {
        poseEngine.clearEMGBaseline()
    }

    func startSessionScoring(for pose: YORILivePose) {
        if pose == .catCow {
            poseEngine.resetCatCowWindow()
            lastProcessedCatCowSequence = sensorState.flexMain?.sequence
        }
        sessionEvaluator.startSession(pose: pose)
    }

    func pauseSessionScoring() {
        sessionEvaluator.pauseSession()
    }

    func resumeSessionScoring() {
        sessionEvaluator.resumeSession()
    }

    func finishSessionScoring() -> YORISessionResult? {
        sessionEvaluator.finishSession()
    }

    func cancelSessionScoring() {
        sessionEvaluator.cancelSession()
    }

    var mountainEvaluation: YORILiveMountainEvaluation? {
        guard case let .mountain(evaluation) = liveResult else { return nil }
        return evaluation
    }

    var catCowEvaluation: YORILiveCatCowEvaluation? {
        guard case let .catCow(evaluation) = liveResult else { return nil }
        return evaluation
    }

    private func observeSensorSources() {
        flexBLEManager.$connectionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleFlexConnectionState(state)
            }
            .store(in: &cancellables)

        flexBLEManager.$isMainStreamFresh
            .removeDuplicates()
            .sink { [weak self] isFresh in
                self?.handleFlexMainStreamFreshness(isFresh)
            }
            .store(in: &cancellables)

        flexBLEManager.$latestMainSample
            .compactMap { $0 }
            .sink { [weak self] sample in
                self?.handleFlexMainSample(sample)
            }
            .store(in: &cancellables)

        flexBLEManager.$latestGyroscopeSample
            .compactMap { $0 }
            .sink { [weak self] sample in
                self?.handleFlexGyroscopeSample(sample)
            }
            .store(in: &cancellables)

        matBLEManager.$status
            .removeDuplicates()
            .sink { [weak self] status in
                self?.handleMatConnectionStatus(status)
            }
            .store(in: &cancellables)

        matBLEManager.$latestPressureSample
            .compactMap { $0 }
            .sink { [weak self] sample in
                self?.handleMatPressureSample(sample)
            }
            .store(in: &cancellables)
    }

    private func handleFlexConnectionState(_ state: YORIFlexConnectionState) {
        let isConnected = state == .connected
        sensorState.isFlexConnected = isConnected
        sensorState.isFlexMainStreamFresh = isConnected
            && flexBLEManager.isMainStreamFresh

        guard !isConnected else { return }

        clearFlexRealtimeData()
    }

    private func handleFlexMainStreamFreshness(_ isFresh: Bool) {
        sensorState.isFlexMainStreamFresh = sensorState.isFlexConnected && isFresh
        guard !sensorState.isFlexMainStreamFresh else { return }

        clearFlexRealtimeData()
    }

    private func clearFlexRealtimeData() {
        sensorState.flexMain = nil
        sensorState.flexGyroscope = nil
        liveResult = nil
        lastProcessedCatCowSequence = nil
        poseEngine.resetCatCowWindow()

        #if DEBUG
        debugSnapshot = nil
        #endif
    }

    private func handleMatConnectionStatus(_ status: BLEConnectionStatus) {
        let isConnected = status == .connected
        sensorState.isMatConnected = isConnected

        if !isConnected {
            sensorState.matPressure = nil
        }

        refreshPressureResult()
    }

    private func handleFlexMainSample(_ sample: YORIFlexMainSensorSample) {
        guard
            sensorState.isFlexConnected,
            sensorState.isFlexMainStreamFresh
        else {
            return
        }

        sensorState.flexMain = sample

        guard isEvaluationActive else { return }

        switch currentPose {
        case .mountain:
            evaluateMountainIfPossible()
        case .catCow:
            evaluateCatCowIfPossible()
        case nil:
            break
        }
    }

    private func handleFlexGyroscopeSample(_ sample: YORIFlexGyroscopeSample) {
        guard
            sensorState.isFlexConnected,
            sensorState.isFlexMainStreamFresh
        else {
            return
        }

        sensorState.flexGyroscope = sample

        if isEvaluationActive {
            sessionEvaluator.ingestGyroscope(sample)
            if currentPose == .catCow {
                evaluateCatCowIfPossible()
            }
        }
    }

    private func handleMatPressureSample(_ sample: YORIMatPressureSample) {
        guard sensorState.isMatConnected else { return }

        sensorState.matPressure = sample
        if isEvaluationActive {
            if let pressureResult = sessionPressureResult(for: sample) {
                sessionEvaluator.ingestPressure(pressureResult)
            }
            refreshPressureResult()
        }
    }

    private func evaluateMountainIfPossible() {
        guard
            currentPose == .mountain,
            let mainSample = sensorState.flexMain
        else {
            return
        }

        let result = poseEngine.evaluateMountain(
            YORIMountainInput(
                t3Roll: mainSample.t3Roll,
                t3Pitch: mainSample.t3Pitch,
                t12Roll: mainSample.t12Roll,
                t12Pitch: mainSample.t12Pitch,
                s1Roll: mainSample.s1Roll,
                s1Pitch: mainSample.s1Pitch
            )
        )
        let evaluation = YORILiveMountainEvaluation(
            poseResult: result,
            pressureResult: mountainPressureResult()
        )

        liveResult = .mountain(evaluation)
        sessionEvaluator.ingestMountain(result: result, sample: mainSample)
        updateDebugState(for: evaluation, timestamp: mainSample.timestamp)
    }

    private func evaluateCatCowIfPossible() {
        guard
            currentPose == .catCow,
            let mainSample = sensorState.flexMain,
            let gyroscopeSample = sensorState.flexGyroscope,
            mainSample.sequence == gyroscopeSample.sequence,
            lastProcessedCatCowSequence != mainSample.sequence
        else {
            return
        }

        let frame = YORICatCowFrame(
            timestamp: max(mainSample.timestamp, gyroscopeSample.timestamp)
                - catCowPausedDuration,
            t3Pitch: mainSample.t3Pitch,
            t12Pitch: mainSample.t12Pitch,
            s1Pitch: mainSample.s1Pitch,
            t3Gyro: gyroscopeSample.t3,
            t12Gyro: gyroscopeSample.t12,
            s1Gyro: gyroscopeSample.s1,
            emg1: mainSample.emg1,
            emg2: mainSample.emg2
        )
        let result = poseEngine.ingestCatCowFrame(frame)
        let evaluation = YORILiveCatCowEvaluation(
            poseResult: result,
            pressureResult: catCowPressureResult()
        )

        lastProcessedCatCowSequence = mainSample.sequence
        liveResult = .catCow(evaluation)
        sessionEvaluator.ingestCatCow(result: result, timestamp: frame.timestamp)
        updateDebugState(for: evaluation, timestamp: frame.timestamp)
    }

    private func sessionPressureResult(
        for pressure: YORIMatPressureSample
    ) -> YORIPressureResult? {
        switch currentPose {
        case .mountain where pressure.leftFoot + pressure.rightFoot > 0:
            return poseEngine.evaluateMountainPressure(
                leftFoot: Double(pressure.leftFoot),
                rightFoot: Double(pressure.rightFoot)
            )
        case .catCow where pressure.leftHand + pressure.rightHand > 0:
            return poseEngine.evaluateCatCowPressure(
                leftHand: Double(pressure.leftHand),
                rightHand: Double(pressure.rightHand)
            )
        default:
            return nil
        }
    }

    private func refreshPressureResult() {
        switch liveResult {
        case let .mountain(evaluation):
            let updatedEvaluation = YORILiveMountainEvaluation(
                poseResult: evaluation.poseResult,
                pressureResult: mountainPressureResult()
            )
            liveResult = .mountain(updatedEvaluation)
            updateDebugState(
                for: updatedEvaluation,
                timestamp: sensorState.matPressure?.timestamp
                    ?? Date().timeIntervalSinceReferenceDate
            )
        case let .catCow(evaluation):
            let updatedEvaluation = YORILiveCatCowEvaluation(
                poseResult: evaluation.poseResult,
                pressureResult: catCowPressureResult()
            )
            liveResult = .catCow(updatedEvaluation)
            updateDebugState(
                for: updatedEvaluation,
                timestamp: sensorState.matPressure?.timestamp
                    ?? Date().timeIntervalSinceReferenceDate
            )
        case nil:
            break
        }
    }

    private func mountainPressureResult() -> YORIPressureResult? {
        guard
            sensorState.isMatConnected,
            let pressure = sensorState.matPressure
        else {
            return nil
        }

        return poseEngine.evaluateMountainPressure(
            leftFoot: Double(pressure.leftFoot),
            rightFoot: Double(pressure.rightFoot)
        )
    }

    private func catCowPressureResult() -> YORIPressureResult? {
        guard
            sensorState.isMatConnected,
            let pressure = sensorState.matPressure
        else {
            return nil
        }

        return poseEngine.evaluateCatCowPressure(
            leftHand: Double(pressure.leftHand),
            rightHand: Double(pressure.rightHand)
        )
    }

    #if DEBUG
    private func updateDebugState(
        for evaluation: YORILiveMountainEvaluation,
        timestamp: TimeInterval
    ) {
        let result = evaluation.poseResult
        debugSnapshot = .mountain(
            state: result.state,
            upperSpinePitch: result.upperSpinePitch,
            lowerSpinePitch: result.lowerSpinePitch,
            pressureSymmetry: evaluation.pressureResult?.symmetry
        )

        guard shouldWriteDebugLog(at: timestamp) else { return }
        let state = String(describing: result.state)
        let symmetry = formatted(evaluation.pressureResult?.symmetry)
        Self.logger.debug(
            "Mountain state=\(state, privacy: .public), T3-T12 pitch=\(result.upperSpinePitch, privacy: .public), T12-S1 pitch=\(result.lowerSpinePitch, privacy: .public), pressure symmetry=\(symmetry, privacy: .public)"
        )
    }

    private func updateDebugState(
        for evaluation: YORILiveCatCowEvaluation,
        timestamp: TimeInterval
    ) {
        let result = evaluation.poseResult
        debugSnapshot = .catCow(
            enoughData: result.hasEnoughDataForEvaluation,
            issues: result.issues,
            upperRange: result.upperRange,
            wholeRange: result.wholeRange,
            gyroRMS: result.gyroRMS,
            emg1ActivationPercent: result.emg1ActivationPercent,
            emg2ActivationPercent: result.emg2ActivationPercent,
            pressureSymmetry: evaluation.pressureResult?.symmetry
        )
    }

    private func startCatCowDiagnosticMonitoring() {
        stopCatCowDiagnosticMonitoring()
        refreshCatCowDiagnostics()

        catCowDiagnosticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }

                guard
                    let self,
                    self.isEvaluationActive,
                    self.currentPose == .catCow
                else {
                    return
                }

                self.refreshCatCowDiagnostics()
            }
        }
    }

    private func stopCatCowDiagnosticMonitoring() {
        catCowDiagnosticTask?.cancel()
        catCowDiagnosticTask = nil
    }

    private func refreshCatCowDiagnostics() {
        let now = Date().timeIntervalSinceReferenceDate
        let evaluation = catCowEvaluation
        let result = evaluation?.poseResult
        let diagnostics = YORICatCowLiveDiagnostics(
            isFlexConnected: sensorState.isFlexConnected,
            mainSampleAge: sampleAge(sensorState.flexMain?.timestamp, at: now),
            gyroscopeSampleAge: sampleAge(sensorState.flexGyroscope?.timestamp, at: now),
            windowDuration: result?.windowDuration ?? 0,
            frameCount: result?.frameCount ?? 0,
            hasEnoughDataForEvaluation: result?.hasEnoughDataForEvaluation ?? false,
            upperRange: result?.upperRange ?? 0,
            lowerRange: result?.lowerRange ?? 0,
            wholeRange: result?.wholeRange ?? 0,
            gyroRMS: result?.gyroRMS ?? 0,
            gyroPeak: result?.gyroPeak ?? 0,
            issues: result?.issues ?? [],
            emg1ActivationPercent: result?.emg1ActivationPercent,
            emg2ActivationPercent: result?.emg2ActivationPercent,
            handPressureSymmetry: evaluation?.pressureResult?.symmetry
        )
        catCowDiagnostics = diagnostics

        let issues = diagnostics.issues.isEmpty
            ? "none"
            : diagnostics.issues.map { String(describing: $0) }.joined(separator: ",")
        print(
            """
            [YORI CatCow]
            mainAge=\(formatted(diagnostics.mainSampleAge))
            gyroAge=\(formatted(diagnostics.gyroscopeSampleAge))
            window=\(formatted(diagnostics.windowDuration))
            frames=\(diagnostics.frameCount)
            enoughData=\(diagnostics.hasEnoughDataForEvaluation)
            upperRange=\(formatted(diagnostics.upperRange))
            wholeRange=\(formatted(diagnostics.wholeRange))
            gyroRMS=\(formatted(diagnostics.gyroRMS))
            issues=\(issues)
            """
        )
    }

    private func sampleAge(_ timestamp: TimeInterval?, at now: TimeInterval) -> TimeInterval? {
        guard let timestamp else { return nil }
        return max(0, now - timestamp)
    }

    private func shouldWriteDebugLog(at timestamp: TimeInterval) -> Bool {
        guard timestamp - lastDebugLogTimestamp >= 1 else { return false }
        lastDebugLogTimestamp = timestamp
        return true
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "%.2f", value)
    }
    #else
    private func updateDebugState(
        for evaluation: YORILiveMountainEvaluation,
        timestamp: TimeInterval
    ) {}

    private func updateDebugState(
        for evaluation: YORILiveCatCowEvaluation,
        timestamp: TimeInterval
    ) {}
    #endif
}
