import Foundation

enum MeetingSummaryTranscriptStore {
    static let filename = "_summary_transcript_selection.json"

    static func load(in weekFolderURL: URL) -> [String: Bool] {
        let url = weekFolderURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return values
    }

    static func save(folderName: String, externalOnly: Bool, in weekFolderURL: URL) throws {
        var values = load(in: weekFolderURL)
        if externalOnly {
            values[folderName] = true
        } else {
            values.removeValue(forKey: folderName)
        }
        let url = weekFolderURL.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: url, options: .atomic)
    }
}
