import Foundation

nonisolated protocol GoogleCalendarReading: Sendable {
    func calendarStatus(for invitation: CalendarInvitation) async throws -> GoogleCalendarStatus?
}
