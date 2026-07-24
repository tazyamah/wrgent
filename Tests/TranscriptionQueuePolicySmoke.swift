import Foundation

@main
struct TranscriptionQueuePolicySmoke {
    static func main() {
        precondition(TranscriptionQueuePolicy.isEligibleForAutomaticTranscription(
            "2026_W28/20260707_110633 - Zoomミーティング",
            currentWeek: "2026_W28"
        ))
        precondition(!TranscriptionQueuePolicy.isEligibleForAutomaticTranscription(
            "2026_W27/20260703_100000 - Zoomミーティング",
            currentWeek: "2026_W28"
        ))
        precondition(!TranscriptionQueuePolicy.isEligibleForAutomaticTranscription(
            "not-a-week/recording",
            currentWeek: "2026_W28"
        ))

        let restored = TranscriptionQueuePolicy.restoredAutomaticQueue(
            from: ["2026_W26/old", "2026_W28/current", "2026_W28/missing"],
            currentWeek: "2026_W28",
            recordingExists: { $0 != "2026_W28/missing" }
        )
        precondition(restored == ["2026_W28/current"])
        precondition(TranscriptionQueuePolicy.nextRunnable(
            in: ["bad", "good", "later"],
            quarantined: ["bad"]
        ) == "good")
        precondition(TranscriptionQueuePolicy.nextRunnable(
            in: ["bad"],
            quarantined: ["bad"]
        ) == nil)
        precondition((1...5).map(TranscriptionQueuePolicy.retryDelaySeconds) == [15, 30, 60, 60, 60])
        precondition((1...7).map(TranscriptionQueuePolicy.automaticStartRetryDelaySeconds) == [10, 20, 40, 80, 120, 120, 120])
        print("TranscriptionQueuePolicy smoke test passed")
    }
}
