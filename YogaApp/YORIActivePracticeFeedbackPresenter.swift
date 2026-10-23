import Combine
import Foundation

struct YORIActivePracticeFeedback: Equatable {
    let title: String
    let message: String
    let pressureResult: YORIPressureResult?
}

@MainActor
final class YORIActivePracticeFeedbackPresenter: ObservableObject {
    @Published private(set) var feedback: YORIActivePracticeFeedback

    private let mountainDebounceNanoseconds: UInt64
    private var pose: YORILivePose
    private var displayedMountainState: YORIMountainState?
    private var pendingMountainState: YORIMountainState?
    private var mountainDebounceTask: Task<Void, Never>?

    init(
        pose: YORILivePose,
        mountainDebounceNanoseconds: UInt64 = 750_000_000
    ) {
        self.pose = pose
        self.mountainDebounceNanoseconds = mountainDebounceNanoseconds
        feedback = Self.initialFeedback(for: pose)
    }

    func reset(for pose: YORILivePose) {
        mountainDebounceTask?.cancel()
        mountainDebounceTask = nil
        self.pose = pose
        displayedMountainState = nil
        pendingMountainState = nil
        feedback = Self.initialFeedback(for: pose)
    }

    func update(with result: YORILiveEvaluationResult) {
        switch (pose, result) {
        case let (.mountain, .mountain(evaluation)):
            updateMountain(evaluation)
        case let (.catCow, .catCow(evaluation)):
            updateCatCow(evaluation)
        default:
            break
        }
    }

    func cancelPendingUpdates() {
        mountainDebounceTask?.cancel()
        mountainDebounceTask = nil
        pendingMountainState = nil
    }

    func updatePressure(with result: YORILiveEvaluationResult) {
        let pressureResult: YORIPressureResult?

        switch (pose, result) {
        case let (.mountain, .mountain(evaluation)):
            pressureResult = evaluation.pressureResult
        case let (.catCow, .catCow(evaluation)):
            pressureResult = evaluation.pressureResult
        default:
            return
        }

        feedback = YORIActivePracticeFeedback(
            title: feedback.title,
            message: feedback.message,
            pressureResult: pressureResult
        )
    }

    private func updateMountain(_ evaluation: YORILiveMountainEvaluation) {
        let state = evaluation.poseResult.state

        if state == displayedMountainState {
            pendingMountainState = nil
            mountainDebounceTask?.cancel()
            mountainDebounceTask = nil
            feedback = mountainFeedback(
                for: state,
                pressureResult: evaluation.pressureResult
            )
            return
        }

        if state == pendingMountainState {
            feedback = YORIActivePracticeFeedback(
                title: feedback.title,
                message: feedback.message,
                pressureResult: evaluation.pressureResult
            )
            return
        }

        pendingMountainState = state
        let debounceNanoseconds = mountainDebounceNanoseconds
        mountainDebounceTask?.cancel()
        mountainDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }

            guard let self, self.pendingMountainState == state else { return }
            self.displayedMountainState = state
            self.pendingMountainState = nil
            self.mountainDebounceTask = nil
            self.feedback = self.mountainFeedback(
                for: state,
                pressureResult: evaluation.pressureResult
            )
        }
    }

    private func updateCatCow(_ evaluation: YORILiveCatCowEvaluation) {
        mountainDebounceTask?.cancel()
        mountainDebounceTask = nil
        let result = evaluation.poseResult

        guard result.hasEnoughDataForEvaluation else {
            feedback = YORIActivePracticeFeedback(
                title: "Keep going!",
                message: "Keep moving smoothly",
                pressureResult: evaluation.pressureResult
            )
            return
        }

        let issues = Set(result.issues)
        let title = issues.isEmpty ? "Great!" : "Adjust"
        let message: String

        switch (
            issues.contains(.incompleteRange),
            issues.contains(.poorControl)
        ) {
        case (false, false):
            message = "Great rhythm and range"
        case (true, false):
            message = "Move through a fuller spinal range"
        case (false, true):
            message = "Slow down and move more smoothly"
        case (true, true):
            message = "Use a fuller range and slow the transition"
        }

        feedback = YORIActivePracticeFeedback(
            title: title,
            message: message,
            pressureResult: evaluation.pressureResult
        )
    }

    private func mountainFeedback(
        for state: YORIMountainState,
        pressureResult: YORIPressureResult?
    ) -> YORIActivePracticeFeedback {
        let title: String
        let message: String

        switch state {
        case .correct:
            title = "Great!"
            message = "Great alignment"
        case .roundedUpperBack:
            title = "Adjust"
            message = "Gently lengthen through your upper spine"
        case .anteriorPelvicTilt:
            title = "Adjust"
            message = "Bring your pelvis toward neutral"
        case .posteriorPelvicTilt:
            title = "Adjust"
            message = "Release the pelvic tuck slightly"
        }

        return YORIActivePracticeFeedback(
            title: title,
            message: message,
            pressureResult: pressureResult
        )
    }

    private static func initialFeedback(for pose: YORILivePose) -> YORIActivePracticeFeedback {
        switch pose {
        case .mountain:
            YORIActivePracticeFeedback(
                title: "Get ready",
                message: "Stand comfortably and settle into position",
                pressureResult: nil
            )
        case .catCow:
            YORIActivePracticeFeedback(
                title: "Keep going!",
                message: "Keep moving smoothly",
                pressureResult: nil
            )
        }
    }
}
