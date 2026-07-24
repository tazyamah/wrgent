import Foundation

struct CalendarEvent: Codable {
    let title: String
    let start: String
    let end: String

    var startDate: Date? { Self.parseDate(start) }
    var endDate:   Date? { Self.parseDate(end) }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: s) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: s) { return date }

        let ftz = DateFormatter()
        ftz.locale = Locale(identifier: "en_US_POSIX")
        ftz.dateFormat = "yyyy-MM-dd'T'HH:mmxxxxx"
        if let d = ftz.date(from: s) { return d }
        let flocal = DateFormatter()
        flocal.locale = Locale(identifier: "en_US_POSIX")
        flocal.dateFormat = "yyyy-MM-dd'T'HH:mm"
        flocal.timeZone = TimeZone.current
        return flocal.date(from: s)
    }
}

private struct CalendarImport: Codable {
    let exported: String?
    let events: [CalendarEvent]
}

enum CalendarStore {

    static func importedCount(in weekFolderURL: URL) -> Int {
        load(in: weekFolderURL).count
    }

    static func load(in weekFolderURL: URL) -> [CalendarEvent] {
        let url = weekFolderURL.appendingPathComponent("_calendar.json")
        guard let data = try? Data(contentsOf: url),
              let imp = try? JSONDecoder().decode(CalendarImport.self, from: data) else { return [] }
        return imp.events
    }

    static func matchEvent(recordingStart: Date, in events: [CalendarEvent]) -> CalendarEvent? {
        let datedEvents = events.compactMap { event -> (event: CalendarEvent, start: Date, end: Date)? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return (event, start, end)
        }

        // Mid-meeting join: prefer the active event whose start is closest in the past.
        let active = datedEvents.filter {
            recordingStart >= $0.start && recordingStart < $0.end
        }
        if let best = active.min(by: {
            recordingStart.timeIntervalSince($0.start) < recordingStart.timeIntervalSince($1.start)
        }) {
            return best.event
        }

        // Early join: when no event is active, use the nearest event starting within 30 minutes.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let future = datedEvents.filter {
            let lead = $0.start.timeIntervalSince(recordingStart)
            return lead > 0
                && lead <= 30 * 60
                && calendar.isDate($0.start, inSameDayAs: recordingStart)
        }
        return future.min(by: {
            $0.start.timeIntervalSince(recordingStart) < $1.start.timeIntervalSince(recordingStart)
        })?.event
    }
}
