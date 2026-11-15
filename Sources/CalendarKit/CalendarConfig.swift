import Foundation

/// Everything CalendarKit needs from the host. The token provider is
/// `@Sendable` + `async` so the host can hand over its current mvServer access
/// token (auto-refreshed) from its own actor. CalendarKit never logs anyone in.
public struct CalendarConfig: Sendable {
    public let baseURL: URL
    /// The signed-in user (mvServer UUID).
    public let currentUserID: UUID
    public let tokenProvider: @Sendable () async -> String?
    /// The host's App-Group identifier for the local store (e.g.
    /// "group.com.example.app"); nil → the app's own container (CalendarLab/dev).
    public let appGroup: String?
    /// How often the calendar refreshes while it's on screen.
    public let refreshInterval: Duration
    // No reminders or notifications of any kind (MVCALE-15): nothing on this
    // calendar announces itself outside the app.

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                appGroup: String? = nil,
                refreshInterval: Duration = .seconds(20)) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.appGroup = appGroup
        self.refreshInterval = refreshInterval
    }

    /// The live transport — Connect/protobuf against mvCalendar.
    public var transport: any CalendarTransport {
        ConnectCalendarTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
