import Foundation

/// Which backend CalendarLab talks to. Auth goes to mvServer (WebSocket via
/// MvAuth); calendar calls go to mvCalendar (Connect via CalendarKit). Same
/// credentials, two services. Develop against **Local** (mvServer + mvCalendar
/// in local Docker).
enum LabServer: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case local = "Local"

    var id: String { rawValue }

    /// mvServer WebSocket endpoint MvAuth logs in against.
    var authWS: URL {
        switch self {
        case .production: URL(string: "wss://api.mvchat.app/v0/ws")!
        case .local:      URL(string: "ws://localhost:6170/v0/ws")!
        }
    }

    /// mvCalendar base URL CalendarKit talks to.
    var calendarBaseURL: URL {
        switch self {
        case .production: URL(string: "https://cal.mvchat.app")!
        // LAB_CAL_BASE points the local Lab at another mvCalendar (a throwaway
        // one for tests); unset, the usual local port.
        case .local:      ProcessInfo.processInfo.environment["LAB_CAL_BASE"].flatMap(URL.init(string:))
                              ?? URL(string: "http://localhost:6100")!
        }
    }
}
