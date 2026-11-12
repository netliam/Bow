import Foundation

/// One stretch of reading, as Grimmory's stats count it.
public struct GrimmoryReadingSession: Codable, Sendable, Equatable {
    public enum BookType: String, Codable, Sendable { case epub = "EPUB", pdf = "PDF" }

    public var bookID: Int64
    public var bookType: BookType
    public var start: Date
    public var end: Date
    /// 0–100.
    public var startProgress: Double?
    public var endProgress: Double?
    /// A CFI (EPUB) or page number (PDF).
    public var startLocation: String?
    public var endLocation: String?

    public var durationSeconds: Int { max(Int(end.timeIntervalSince(start)), 0) }

    public init(bookID: Int64, bookType: BookType, start: Date, end: Date, startProgress: Double? = nil,
                endProgress: Double? = nil, startLocation: String? = nil, endLocation: String? = nil) {
        self.bookID = bookID
        self.bookType = bookType
        self.start = start
        self.end = end
        self.startProgress = startProgress
        self.endProgress = endProgress
        self.startLocation = startLocation
        self.endLocation = endLocation
    }
}

/// The reading statistics Bow shows, as Grimmory's web app computes them.
public struct GrimmoryReadingStats: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        /// `yyyy-MM-dd`.
        public var date: String
        public var active: Bool
    }

    public var currentStreak = 0
    public var longestStreak = 0
    public var totalReadingDays = 0
    /// The last year, a day at a time, oldest first.
    public var lastYear: [Day] = []
    /// Reading time this year by hour of day (0–23), in seconds.
    public var secondsByHour: [Int: Int] = [:]
    /// Reading time this year by weekday name ("Monday"…), in seconds, in Grimmory's order.
    public var secondsByWeekday: [(day: String, seconds: Int)] = []
    /// Genre and the number of books read in it, most first.
    public var genres: [(genre: String, books: Int)] = []
    public var booksFinishedThisYear = 0

    public var secondsThisYear: Int { secondsByHour.values.reduce(0, +) }

    public static func == (a: Self, b: Self) -> Bool {
        a.currentStreak == b.currentStreak && a.longestStreak == b.longestStreak && a.lastYear == b.lastYear
            && a.secondsByHour == b.secondsByHour && a.booksFinishedThisYear == b.booksFinishedThisYear
    }
}

extension GrimmoryClient {
    // MARK: Reading sessions

    public func record(_ session: GrimmoryReadingSession) async throws {
        let body = Components.Schemas.ReadingSessionRequest(
            bookId: session.bookID,
            bookType: .init(rawValue: session.bookType.rawValue),
            durationSeconds: Int32(session.durationSeconds),
            endLocation: session.endLocation,
            endProgress: session.endProgress.map(Float.init),
            endTime: session.end,
            progressDelta: zip(session.startProgress, session.endProgress).map { Float($1 - $0) },
            startLocation: session.startLocation,
            startProgress: session.startProgress.map(Float.init),
            startTime: session.start
        )
        let output = try await unwrapped { try await client.recordReadingSession(body: .json(body)) }
        guard case .accepted = output else { throw GrimmoryError(status: statusCode(of: output)) }
    }

    // MARK: Statistics

    /// Everything the stats screen shows, for `year`. Needs the `canAccessUserStats` permission (403 without).
    public func readingStats(year: Int) async throws -> GrimmoryReadingStats {
        let y = Int32(year)
        async let streakCall = unwrapped { try await client.getReadingStreak() }
        async let hoursCall = unwrapped { try await client.getPeakReadingHours(query: .init(year: y)) }
        async let daysCall = unwrapped { try await client.getFavoriteReadingDays(query: .init(year: y)) }
        async let genresCall = unwrapped { try await client.getGenreStatistics() }
        async let completionCall = unwrapped { try await client.getCompletionTimeline(query: .init(year: y)) }

        var stats = GrimmoryReadingStats()
        let streakOutput = try await streakCall
        guard case .ok(let streakOK) = streakOutput else { throw GrimmoryError(status: statusCode(of: streakOutput)) }
        let streak = try streakOK.body.json
        stats.currentStreak = Int(streak.currentStreak ?? 0)
        stats.longestStreak = Int(streak.longestStreak ?? 0)
        stats.totalReadingDays = Int(streak.totalReadingDays ?? 0)
        stats.lastYear = (streak.last52Weeks ?? []).compactMap { day in
            day.date.map { GrimmoryReadingStats.Day(date: $0, active: day.active ?? false) }
        }

        // The rest are extras: one failing leaves its part of the screen empty, not the whole screen.
        if case .ok(let ok)? = try? await hoursCall, let hours = try? ok.body.json {
            for hour in hours { stats.secondsByHour[Int(hour.hourOfDay ?? 0)] = Int(hour.totalDurationSeconds ?? 0) }
        }
        if case .ok(let ok)? = try? await daysCall, let days = try? ok.body.json {
            stats.secondsByWeekday = days.map { ($0.dayName ?? "", Int($0.totalDurationSeconds ?? 0)) }
        }
        if case .ok(let ok)? = try? await genresCall, let genres = try? ok.body.json {
            stats.genres = genres.compactMap { g in g.genre.map { ($0, Int(g.bookCount ?? 0)) } }
                .sorted { $0.books > $1.books }
        }
        if case .ok(let ok)? = try? await completionCall, let months = try? ok.body.json {
            stats.booksFinishedThisYear = months.reduce(0) { $0 + Int($1.finishedBooks ?? 0) }
        }
        return stats
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
