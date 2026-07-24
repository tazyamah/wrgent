import Foundation

enum TranscriptionQueuePolicy {
    static func nextRunnable(in queue: [String], quarantined: Set<String>) -> String? {
        queue.first { !quarantined.contains($0) }
    }

    static func retryDelaySeconds(attempt: Int) -> Int {
        let exponent = min(2, max(0, attempt - 1))
        return min(60, 15 * (1 << exponent))
    }

    static func automaticStartRetryDelaySeconds(failureCount: Int) -> Int {
        let exponent = min(4, max(0, failureCount - 1))
        return min(120, 10 * (1 << exponent))
    }

    static func weekName(from path: String) -> String? {
        guard let first = path.split(separator: "/", maxSplits: 1).first else { return nil }
        let week = String(first)
        guard week.range(of: #"^\d{4}_W\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return week
    }

    static func isEligibleForAutomaticTranscription(_ path: String, currentWeek: String) -> Bool {
        weekName(from: path) == currentWeek
    }

    static func restoredAutomaticQueue(
        from saved: [String],
        currentWeek: String,
        recordingExists: (String) -> Bool
    ) -> [String] {
        saved.filter {
            isEligibleForAutomaticTranscription($0, currentWeek: currentWeek) && recordingExists($0)
        }
    }
}
