import Foundation

final class RecLog: @unchecked Sendable {
    static let shared = RecLog()

    private let queue = DispatchQueue(label: "wrgent.log", qos: .utility)
    private var url: URL?
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    func configure(folder: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let u = folder.appendingPathComponent("wrgent_log.txt")
            self.url = u
            if !FileManager.default.fileExists(atPath: u.path) {
                FileManager.default.createFile(atPath: u.path, contents: nil)
            }
            self.write("==================== session start ====================")
        }
    }

    func log(_ message: String) {
        queue.async { [weak self] in self?.write(message) }
    }

    private func write(_ message: String) {
        let line = "[\(df.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let u = url else { return }
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }
}
