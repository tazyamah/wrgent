import Foundation

enum MeetingNameStore {
    private static let filename = "_meeting_names.json"

    static func load(in libraryURL: URL) -> [String: String] {
        let url = libraryURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func save(folderName: String, name: String, in libraryURL: URL) throws {
        var dict = load(in: libraryURL)
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            dict.removeValue(forKey: folderName)
        } else {
            dict[folderName] = name
        }
        let url = libraryURL.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(dict).write(to: url, options: .atomic)
    }
}
