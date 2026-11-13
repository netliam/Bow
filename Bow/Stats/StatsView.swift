import BowModel
import BowSync
import Charts
import GrimmoryAPI
import SwiftData
import SwiftUI

/// The reading stats Grimmory keeps for the first server account, kept while the app runs.
@MainActor
@Observable
final class ReadingStatsStore {
    enum State {
        case idle, loading
        case loaded(GrimmoryReadingStats)
        case failed(String)
    }

    private(set) var state: State = .idle

    var stats: GrimmoryReadingStats? {
        if case .loaded(let stats) = state { stats } else { nil }
    }

    func load(from accounts: [Account]) async {
        // shortcut: stats come from the first server only; merge accounts if people use several.
        guard let account = accounts.first(where: { $0.kind == .grimmory }),
              let client = GrimmoryAccounts.client(for: account)
        else { return }
        if case .idle = state { state = .loading }
        do {
            state = .loaded(try await client.readingStats(year: Calendar.current.component(.year, from: Date())))
        } catch GrimmoryError.forbidden {
            state = .failed("Your account on \(account.displayName) can't see reading stats.")
        } catch {
            if stats == nil { state = .failed("Couldn't load your reading stats.") }  // Keep the last ones offline.
        }
    }
}

/// The full reading stats page.
struct StatsView: View {
    @Environment(ReadingStatsStore.self) private var store
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    var body: some View {
        ScrollView {
            switch store.state {
            case .loaded(let stats): content(stats)
            case .failed(let message):
                ContentUnavailableView("No Stats", systemImage: "chart.bar", description: Text(message))
                    .padding(.top, 60)
            case .idle, .loading:
                ProgressView().padding(.top, 80)
            }
        }
        .navigationTitle("Reading Stats")
        .refreshable { await store.load(from: accounts) }
        .task { await store.load(from: accounts) }
    }

    @ViewBuilder
    private func content(_ stats: GrimmoryReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            streak(stats)
            activity(stats)
            if stats.secondsThisYear > 0 {
                hours(stats)
                weekdays(stats)
            } else {
                Text("Read a book in Bow or Grimmory and your reading times show up here.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            if !stats.genres.isEmpty { genres(stats) }
        }
        .padding(.vertical)
    }

    private func streak(_ stats: GrimmoryReadingStats) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile("\(stats.currentStreak)", "Current streak", "flame.fill", .orange)
                tile("\(stats.longestStreak)", "Longest streak", "trophy.fill", .yellow)
            }
            GridRow {
                tile(Self.hours(stats.secondsThisYear), "Read this year", "clock.fill", .blue)
                tile("\(stats.booksFinishedThisYear)", "Finished this year", "checkmark.seal.fill", .green)
            }
        }
        .padding(.horizontal)
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.title.bold()).fontDesign(.serif)
            Text(label).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// The last year as a grid of days, a column per week, like the web app's.
    private func activity(_ stats: GrimmoryReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Activity", subtitle: stats.totalReadingDays == 1
                ? "1 reading day in the last year" : "\(stats.totalReadingDays) reading days in the last year")
            ScrollView(.horizontal) {
                // Weeks run Monday to Sunday down each column, as on Grimmory's web page.
                HStack(alignment: .top, spacing: 3) {
                    let days = Self.alignedToWeeks(stats.lastYear)
                    ForEach(Array(stride(from: 0, to: days.count, by: 7)), id: \.self) { start in
                        VStack(spacing: 3) {
                            ForEach(start..<min(start + 7, days.count), id: \.self) { index in
                                let day = days[index]
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(day?.active == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary))
                                    .opacity(day == nil ? 0 : 1)  // Padding before the first day.
                                    .frame(width: 11, height: 11)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .defaultScrollAnchor(.trailing)  // Today, on the right.
            .scrollIndicators(.hidden)
            .accessibilityElement()
            .accessibilityLabel("Read on \(stats.totalReadingDays) days in the last year")
        }
    }

    private func hours(_ stats: GrimmoryReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Time of Day", subtitle: "When you read this year")
            Chart(0..<24, id: \.self) { hour in
                BarMark(x: .value("Hour", hour), y: .value("Minutes", (stats.secondsByHour[hour] ?? 0) / 60))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel { Text(Self.hourLabel(value.as(Int.self) ?? 0)) }
                }
            }
            .chartYAxisLabel("min")
            .frame(height: 160)
            .padding(.horizontal)
        }
    }

    private func weekdays(_ stats: GrimmoryReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Days of the Week")
            Chart(stats.secondsByWeekday, id: \.day) { day in
                BarMark(x: .value("Day", String(day.day.prefix(3))), y: .value("Minutes", day.seconds / 60))
                    .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxisLabel("min")
            .frame(height: 160)
            .padding(.horizontal)
        }
    }

    private func genres(_ stats: GrimmoryReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Genres")
            ForEach(stats.genres.prefix(6), id: \.genre) { genre in
                HStack {
                    Text(genre.genre)
                    Spacer()
                    Text(genre.books == 1 ? "1 book" : "\(genre.books) books").foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
        }
    }

    /// Pads the start so the first day sits in its weekday's row (Monday first). Grimmory's list starts on
    /// whatever weekday fell a year ago.
    static func alignedToWeeks(_ days: [GrimmoryReadingStats.Day]) -> [GrimmoryReadingStats.Day?] {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let first = days.first.flatMap({ parser.date(from: $0.date) }) else { return days }
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: first)  // Sunday = 1
        let padding = (weekday + 5) % 7  // Days since Monday.
        return Array(repeating: nil, count: padding) + days.map { $0 }
    }

    /// "12 h" or "45 min".
    static func hours(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600) h" : "\(seconds / 60) min"
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}
