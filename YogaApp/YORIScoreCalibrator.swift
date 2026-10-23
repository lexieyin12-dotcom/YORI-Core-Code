import Foundation

struct YORISessionDimensionScores: Equatable {
    let alignment: Double
    let stability: Double
    let control: Double
}

enum YORIScoreCalibrator {
    private struct Anchor {
        let raw: Double
        let final: Double
    }

    // Prototype training-score calibration curves derived from iterative
    // real-device usability testing. They are not medical, clinical, or
    // pediatric normative scoring curves.
    private static let alignmentAnchors = [
        Anchor(raw: 0, final: 55),
        Anchor(raw: 40, final: 65),
        Anchor(raw: 60, final: 72),
        Anchor(raw: 75, final: 80),
        Anchor(raw: 85, final: 87),
        Anchor(raw: 92, final: 92),
        Anchor(raw: 97, final: 95),
        Anchor(raw: 100, final: 97)
    ]

    // Shared by Mountain and Cat-Cow after each pose computes its own raw
    // Stability and Control scores.
    private static let stabilityAndControlAnchors = [
        Anchor(raw: 0, final: 65),
        Anchor(raw: 10, final: 69),
        Anchor(raw: 20, final: 73),
        Anchor(raw: 30, final: 77),
        Anchor(raw: 40, final: 80),
        Anchor(raw: 50, final: 83),
        Anchor(raw: 60, final: 86),
        Anchor(raw: 70, final: 89),
        Anchor(raw: 80, final: 92),
        Anchor(raw: 90, final: 95),
        Anchor(raw: 100, final: 97)
    ]

    static func calibrate(_ rawScores: YORISessionDimensionScores) -> YORISessionDimensionScores {
        YORISessionDimensionScores(
            alignment: alignmentScore(from: rawScores.alignment),
            stability: stabilityScore(from: rawScores.stability),
            control: controlScore(from: rawScores.control)
        )
    }

    static func alignmentScore(from rawScore: Double) -> Double {
        interpolate(rawScore, using: alignmentAnchors)
    }

    static func stabilityScore(from rawScore: Double) -> Double {
        interpolate(rawScore, using: stabilityAndControlAnchors)
    }

    static func controlScore(from rawScore: Double) -> Double {
        interpolate(rawScore, using: stabilityAndControlAnchors)
    }

    private static func interpolate(_ rawScore: Double, using anchors: [Anchor]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        let boundedRawScore = min(max(rawScore, first.raw), last.raw)

        if boundedRawScore <= first.raw {
            return first.final
        }

        for (lower, upper) in zip(anchors, anchors.dropFirst())
        where boundedRawScore <= upper.raw {
            let progress = (boundedRawScore - lower.raw) / (upper.raw - lower.raw)
            return lower.final + progress * (upper.final - lower.final)
        }

        return last.final
    }
}
