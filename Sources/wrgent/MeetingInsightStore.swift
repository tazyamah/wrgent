import Foundation

enum MeetingInsightStore {
    static let filename = "_insight_selection.json"

    static func load(in weekFolderURL: URL) -> [String: Bool] {
        let url = weekFolderURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return values
    }

    static func isIncluded(folderName: String, in weekFolderURL: URL) -> Bool {
        load(in: weekFolderURL)[folderName] ?? true
    }

    static func save(folderName: String, included: Bool, in weekFolderURL: URL) throws {
        var values = load(in: weekFolderURL)
        if included {
            values.removeValue(forKey: folderName)
        } else {
            values[folderName] = false
        }
        let url = weekFolderURL.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: url, options: .atomic)
    }
}
