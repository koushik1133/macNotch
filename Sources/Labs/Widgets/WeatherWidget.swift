import AppKit
import Combine
import SwiftUI

// MARK: - Controller

/// Weather from Open-Meteo (free, no account, no key) for a city the user
/// types. Off until a city is chosen: nothing leaves the Mac before that.
/// Then the forecast for the city's coordinates (rounded to 2 decimals) is
/// fetched at most every 30 minutes, and only while weather is on screen;
/// with rain alerts on, once an hour in the background too. Never while
/// the Mac sleeps. The last forecast is cached and shown with its time when
/// offline. No CoreLocation, no location permission.
@MainActor
final class WeatherController: ObservableObject {
    static let shared = WeatherController()

    enum Keys {
        static let place = "weather.place"
        static let units = "weather.units"
        static let rainAlerts = "weather.rainAlerts"
        static let rainThreshold = "weather.rainThreshold"
        static let cache = "weather.cache"
        static let lastRainAlert = "weather.lastRainAlert"
        static let showsOnHome = "weather.showsOnHome"
    }

    enum Status: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// Fetch while on screen at most this often.
    static let refreshInterval: TimeInterval = 30 * 60
    /// Background fetches for rain alerts.
    static let backgroundInterval: TimeInterval = 60 * 60
    static let thresholdChoices = [40, 50, 60, 70, 80]

    @Published private(set) var place: WeatherPlace?
    @Published var units: WeatherUnits { didSet { defaults.set(units.rawValue, forKey: Keys.units) } }
    /// A short band under the notch when rain is likely within the hour.
    @Published var rainAlerts: Bool {
        didSet {
            guard rainAlerts != oldValue else { return }
            defaults.set(rainAlerts, forKey: Keys.rainAlerts)
            AppLog.log("Weather: rain alerts \(rainAlerts ? "on" : "off")")
            if rainAlerts { refreshIfStale() }
            reschedule()
        }
    }
    @Published var rainThreshold: Int { didSet { defaults.set(rainThreshold, forKey: Keys.rainThreshold) } }
    /// With a city set, Home shows the day's weather where the volume knob
    /// sits. On by default; nothing shows (or is fetched) until a city is set.
    @Published var showsOnHome: Bool { didSet { defaults.set(showsOnHome, forKey: Keys.showsOnHome) } }
    @Published private(set) var forecast: WeatherForecast?
    @Published private(set) var status: Status = .idle

    // City search (sends what is typed to Open-Meteo's geocoding).
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [WeatherPlace] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchMessage: String?

    var isConfigured: Bool { place != nil }

    /// Tests and renders replace the network.
    var fetcher: (@Sendable (URL) async throws -> Data)?

    private let defaults: UserDefaults
    private let session: URLSession
    private weak var activities: ActivityCenter?
    private var viewers = 0
    private var isStarted = false
    private var isAsleep = false
    private var failures = 0
    private var refreshTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["User-Agent": "SparkV (macOS notch app)"]
        session = URLSession(configuration: configuration)
        if let data = defaults.data(forKey: Keys.place) {
            place = try? JSONDecoder().decode(WeatherPlace.self, from: data)
        }
        units = defaults.string(forKey: Keys.units).flatMap(WeatherUnits.init(rawValue:)) ?? .automatic
        rainAlerts = defaults.object(forKey: Keys.rainAlerts) as? Bool ?? false
        let threshold = defaults.integer(forKey: Keys.rainThreshold)
        rainThreshold = Self.thresholdChoices.contains(threshold) ? threshold : 60
        showsOnHome = defaults.object(forKey: Keys.showsOnHome) as? Bool ?? true
        if place != nil, let data = defaults.data(forKey: Keys.cache) {
            forecast = try? JSONDecoder().decode(WeatherForecast.self, from: data)
        }
    }

    // MARK: Lifecycle

    /// Watches sleep and wake; with rain alerts on, keeps the hourly fetch.
    func start(activities: ActivityCenter? = nil) {
        if let activities { self.activities = activities }
        guard !isStarted else { return }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.reschedule()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = false
                if self.viewers > 0 || self.rainAlerts { self.refreshIfStale() }
                self.reschedule()
            }
        })
        if rainAlerts { refreshIfStale() }
        reschedule()
    }

    func stop() {
        isStarted = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        refreshTask?.cancel()
        scheduleTask?.cancel()
        searchTask?.cancel()
        refreshTask = nil
        scheduleTask = nil
    }

    /// A view showing weather appeared (reference-counted).
    func retain() {
        viewers += 1
        refreshIfStale()
        reschedule()
    }

    func release() {
        viewers = max(0, viewers - 1)
        reschedule()
    }

    // MARK: Place

    func setPlace(_ newPlace: WeatherPlace?) {
        // A fetch for the previous city is no longer wanted.
        refreshTask?.cancel()
        refreshTask = nil
        place = newPlace
        forecast = nil
        status = .idle
        failures = 0
        query = ""
        results = []
        if let newPlace, let data = try? JSONEncoder().encode(newPlace) {
            defaults.set(data, forKey: Keys.place)
            AppLog.log("Weather: city set (on)")
            refresh()
        } else {
            defaults.removeObject(forKey: Keys.place)
            defaults.removeObject(forKey: Keys.cache)
            activities?.dismiss(id: Self.rainActivityID)
            AppLog.log("Weather: city cleared (off)")
        }
        reschedule()
    }

    /// Renders and tests: a forecast without the network.
    func setSample(place: WeatherPlace, forecast: WeatherForecast) {
        self.place = place
        self.forecast = forecast
        status = .idle
    }

    // MARK: Fetching

    func refreshIfStale() {
        guard isConfigured, !isAsleep else { return }
        if let forecast, !forecast.isStale(at: Date(), maxAge: Self.refreshInterval) { return }
        refresh()
    }

    /// Fetches now (the Refresh button, a new city).
    func refresh() {
        guard let place, refreshTask == nil else { return }
        status = .loading
        let url = OpenMeteo.forecastURL(for: place)
        let load = loader
        refreshTask = Task { [weak self] in
            let result: Result<WeatherForecast, Error>
            do {
                let data = try await load(url)
                result = .success(try OpenMeteo.decodeForecast(data, fetchedAt: Date()))
            } catch {
                result = .failure(error)
            }
            self?.finish(result, for: place)
        }
    }

    private func finish(_ result: Result<WeatherForecast, Error>, for requested: WeatherPlace) {
        guard requested == place else { return }
        refreshTask = nil
        switch result {
        case .success(let fresh):
            forecast = fresh
            status = .idle
            failures = 0
            if let data = try? JSONEncoder().encode(fresh) { defaults.set(data, forKey: Keys.cache) }
            checkRain(fresh)
        case .failure(let error):
            failures += 1
            let message = (error as? URLError).map(Self.describe) ?? error.localizedDescription
            status = .failed(message)
            AppLog.log("Weather: fetch failed (\(failures)): \(message)")
        }
        reschedule()
    }

    private var loader: @Sendable (URL) async throws -> Data {
        if let fetcher { return fetcher }
        let session = self.session
        return { url in
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 400 {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: "Offline"
        case .timedOut: "Open-Meteo didn't answer"
        default: "Couldn't load the forecast"
        }
    }

    /// One pending wake: every 30 min while shown, hourly for rain alerts,
    /// backing off (2, 4 … 60 min) after failures; none while asleep.
    private func reschedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard isConfigured, !isAsleep else { return }
        let base: TimeInterval
        if viewers > 0 {
            base = Self.refreshInterval
        } else if rainAlerts, isStarted {
            base = Self.backgroundInterval
        } else {
            return
        }
        let delay: TimeInterval
        if failures > 0 {
            delay = min(Self.backgroundInterval, 60 * pow(2, Double(min(failures, 6))))
        } else if let forecast {
            delay = max(30, base - Date().timeIntervalSince(forecast.fetchedAt))
        } else {
            delay = 30
        }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.scheduleTask = nil
            self.refresh()
        }
    }

    // MARK: Rain alerts

    static let rainActivityID = "weather.rain"

    private func checkRain(_ forecast: WeatherForecast) {
        guard rainAlerts, let hour = RainAlert.upcoming(in: forecast, now: Date(), threshold: rainThreshold) else { return }
        let last = defaults.object(forKey: Keys.lastRainAlert) as? Date
        // Once per rainy hour.
        guard last != hour.time else { return }
        defaults.set(hour.time, forKey: Keys.lastRainAlert)
        let text = "Rain likely around \(WeatherFormat.hour(hour.time, zone: forecast.timeZone)) · \(hour.precipitationProbability)%"
        let city = place?.name ?? ""
        AppLog.log("Weather: rain alert")
        activities?.post(LiveActivity(
            id: Self.rainActivityID,
            kind: .notification,
            priority: 55,
            duration: 6,
            opensTab: .today,
            symbol: "cloud.rain.fill",
            tint: SparkVTheme.choose(apple: Color.cyan, sparkv: SparkVTheme.red),
            compactText: "\(hour.precipitationProbability)%"
        ) {
            WeatherRainBand(text: text, city: city)
        })
    }

    // MARK: City search

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard let url = OpenMeteo.geocodingURL(query: text) else {
            results = []
            isSearching = false
            searchMessage = nil
            return
        }
        isSearching = true
        let load = loader
        searchTask = Task { [weak self] in
            // Waits for a pause in typing before anything is sent.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let found: Result<[WeatherPlace], Error>
            do {
                found = .success(try OpenMeteo.decodePlaces(try await load(url)))
            } catch {
                found = .failure(error)
            }
            guard !Task.isCancelled, let self, self.query == text else { return }
            self.isSearching = false
            switch found {
            case .success(let places):
                self.results = places
                self.searchMessage = places.isEmpty ? "No city called “\(text)”" : nil
            case .failure(let error):
                self.results = []
                self.searchMessage = (error as? URLError).map(Self.describe) ?? "Search failed"
            }
        }
    }

    // MARK: Read-outs

    func temperature(_ celsius: Double) -> String { units.degrees(celsius) }

    /// "Updated 10:42" (or "Updating…").
    var updatedText: String {
        if status == .loading { return "Updating…" }
        guard let forecast else { return "" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let stale = forecast.isStale(at: Date(), maxAge: 2 * Self.backgroundInterval)
        return (stale ? "From " : "Updated ") + formatter.string(from: forecast.fetchedAt)
    }

    /// One line for Home and VoiceOver: "London 12°, partly cloudy, 14° / 8°".
    var summary: String? {
        guard let place, let forecast else { return nil }
        var text = "\(place.name) \(temperature(forecast.current.temperature)), \(WeatherCode.description(forecast.current.code).lowercased())"
        if let day = forecast.day(containing: Date()) {
            text += ", high \(temperature(day.high)), low \(temperature(day.low))"
            if day.precipitationProbability >= WeatherFormat.rainShownFrom {
                text += ", \(day.precipitationProbability)% chance of rain"
            }
        }
        return text
    }

    /// Home shows the weather instead of the volume knob.
    var showsHomeGlance: Bool { isConfigured && showsOnHome }
}

enum WeatherFormat {
    /// Rain chances below this aren't shown.
    static let rainShownFrom = 20

    /// Rain percentages: cyan in Apple, the look's secondary text in SparkV Red.
    @MainActor static var rainColor: Color {
        SparkVTheme.choose(apple: Color.cyan.opacity(0.9), sparkv: SparkVTheme.textSecondary)
    }

    /// What leaves the Mac, for every place a city can be typed.
    static let disclosure = "Typing sends the text to Open-Meteo’s city search. A chosen city’s coordinates (rounded to about 1 km) are sent for its forecast."

    /// "3 PM" or "15" in the city's time zone.
    static func hour(_ date: Date, zone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date).replacingOccurrences(of: " ", with: "\u{202F}")
    }

    /// "Wed" in the city's time zone.
    static func weekday(_ date: Date, zone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}

/// Starts and stops weather fetching with a view's visibility.
private struct WeatherVisibility: ViewModifier {
    let controller: WeatherController

    func body(content: Content) -> some View {
        content
            .onAppear { controller.retain() }
            .onDisappear { controller.release() }
    }
}

extension View {
    /// Weather refreshes (at most every 30 min) only while this view shows.
    /// (A default argument is evaluated outside the main actor, so the
    /// shared controller is looked up inside.)
    @MainActor func weatherVisible(_ controller: WeatherController? = nil) -> some View {
        modifier(WeatherVisibility(controller: controller ?? .shared))
    }
}

// MARK: - Views

/// A weather symbol: multicolor in Apple, monochrome in SparkV Red.
struct WeatherGlyph: View {
    let code: Int
    var isDay = true
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: WeatherCode.symbol(code, isDay: isDay))
            .symbolRenderingMode(SparkVTheme.isApple ? .multicolor : .hierarchical)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(SparkVTheme.isApple ? Color.white : SparkVTheme.text)
            .frame(width: size * 1.35, height: size * 1.15)
            .accessibilityLabel(WeatherCode.description(code))
    }
}

/// Weather on the widget grid: small (now), wide (now + next hours),
/// large (now, hours and the next days).
struct WeatherWidget: View {
    @ObservedObject var controller: WeatherController = .shared
    var size: WidgetSize = .wide
    /// Opens the city picker (the Widgets tab's edit page).
    var onEdit: (() -> Void)? = nil
    /// Fixed time for renders.
    var fixedDate: Date? = nil

    var body: some View {
        WidgetCard(padding: size == .small ? 7 : 8) {
            if let place = controller.place, let forecast = controller.forecast {
                content(place: place, forecast: forecast, now: fixedDate ?? Date())
            } else if controller.isConfigured {
                loading
            } else {
                setup
            }
        }
        .weatherVisible(controller)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func content(place: WeatherPlace, forecast: WeatherForecast, now: Date) -> some View {
        let today = forecast.day(containing: now)
        switch size {
        case .small:
            // Fits the 54 pt cells of the tall drawer.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    WeatherGlyph(code: forecast.current.code, isDay: forecast.current.isDay, size: 14)
                    Text(controller.temperature(forecast.current.temperature))
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 3) {
                    Text(place.name)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WidgetStyle.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let today {
                        Text("\(controller.temperature(today.high)) \(controller.temperature(today.low))")
                            .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(WidgetStyle.tertiaryText)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controller.summary ?? "Weather")
        case .wide:
            HStack(spacing: 8) {
                current(place: place, forecast: forecast, today: today, compact: true)
                    .frame(width: 92, alignment: .leading)
                Rectangle().fill(SparkVTheme.stroke).frame(width: 1).padding(.vertical, 3)
                hours(forecast, now: now, count: 4)
            }
        case .large:
            // 242 × 114: now and three days on top, six hours below.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    current(place: place, forecast: forecast, today: today, compact: true)
                    Spacer(minLength: 0)
                    days(forecast, now: now)
                        .frame(width: 98)
                }
                Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
                hours(forecast, now: now, count: 6)
            }
        }
    }

    private func current(place: WeatherPlace, forecast: WeatherForecast, today: WeatherForecast.Day?, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(WidgetStyle.tertiaryText)
                Text(place.name)
                    .font(WidgetStyle.label(9))
                    .tracking(WidgetStyle.labelTracking)
                    .foregroundStyle(WidgetStyle.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                WeatherGlyph(code: forecast.current.code, isDay: forecast.current.isDay, size: compact ? 15 : 19)
                Text(controller.temperature(forecast.current.temperature))
                    .font(.system(size: compact ? 20 : 27, weight: .semibold).monospacedDigit())
                    .tracking(-0.5)
                    .foregroundStyle(SparkVTheme.text)
            }
            Text(compact ? WeatherCode.description(forecast.current.code)
                         : "\(WeatherCode.description(forecast.current.code)) · feels \(controller.temperature(forecast.current.apparent))")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(WidgetStyle.tertiaryText)
                .lineLimit(1)
            if !compact, let today {
                Text("H \(controller.temperature(today.high))  L \(controller.temperature(today.low))")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(WidgetStyle.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.summary ?? "Weather")
    }

    private func hours(_ forecast: WeatherForecast, now: Date, count: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(forecast.upcomingHours(from: now, count: count).enumerated()), id: \.element.time) { index, hour in
                VStack(spacing: 2) {
                    Text(index == 0 ? "Now" : WeatherFormat.hour(hour.time, zone: forecast.timeZone))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(index == 0 ? SparkVTheme.text : WidgetStyle.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    WeatherGlyph(code: hour.code, isDay: hour.isDay, size: 11)
                    Text(controller.temperature(hour.temperature))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                    Text(hour.precipitationProbability >= WeatherFormat.rainShownFrom ? "\(hour.precipitationProbability)%" : " ")
                        .font(.system(size: 7.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(WeatherFormat.rainColor)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(index == 0 ? "Now" : WeatherFormat.hour(hour.time, zone: forecast.timeZone)): \(controller.temperature(hour.temperature)), \(WeatherCode.description(hour.code)), \(hour.precipitationProbability)% chance of rain")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func days(_ forecast: WeatherForecast, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(forecast.daily.filter { $0.date.addingTimeInterval(86_400) > now }.prefix(3).enumerated()), id: \.element.date) { index, day in
                HStack(spacing: 3) {
                    Text(index == 0 ? "Today" : WeatherFormat.weekday(day.date.addingTimeInterval(43_200), zone: forecast.timeZone))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(WidgetStyle.secondaryText)
                        .frame(width: 30, alignment: .leading)
                    WeatherGlyph(code: day.code, size: 9.5)
                    Spacer(minLength: 0)
                    Text("\(controller.temperature(day.high)) \(controller.temperature(day.low))")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SparkVTheme.text)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(index == 0 ? "Today" : WeatherFormat.weekday(day.date, zone: forecast.timeZone)): high \(controller.temperature(day.high)), low \(controller.temperature(day.low)), \(WeatherCode.description(day.code))")
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 4) {
            if case .failed(let message) = controller.status {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(WidgetStyle.tertiaryText)
                Text(message).font(.system(size: 9.5, weight: .medium)).foregroundStyle(WidgetStyle.secondaryText)
                Button("Try Again") { controller.refresh() }
                    .buttonStyle(SparkVPressStyle())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.accent)
            } else {
                ProgressView().controlSize(.small).tint(SparkVTheme.progressTint)
                Text(controller.place?.name ?? "").font(.system(size: 9.5, weight: .medium)).foregroundStyle(WidgetStyle.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setup: some View {
        Button { onEdit?() } label: {
            VStack(spacing: 4) {
                Image(systemName: "cloud.sun.fill")
                    .symbolRenderingMode(SparkVTheme.isApple ? .multicolor : .hierarchical)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WidgetKind.weather.tint)
                Text("Choose a city").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                if size != .small {
                    Text("Weather is off until you do").font(.system(size: 8.5)).foregroundStyle(WidgetStyle.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .accessibilityLabel("Weather is off. Choose a city to turn it on.")
    }
}

/// The rain alert band: "Rain likely around 3 PM · 70%  London".
struct WeatherRainBand: View {
    let text: String
    let city: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.rain.fill")
                .symbolRenderingMode(SparkVTheme.isApple ? .multicolor : .hierarchical)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.isApple ? Color.white : SparkVTheme.text)
                .frame(width: 34, height: 16)
            Text(text)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(city)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// Compact glance (icon and temperature) for headers, Home and hub tiles.
/// With `showsDay`, the day overview too: high / low and the rain chance.
struct WeatherGlance: View {
    @ObservedObject var controller: WeatherController = .shared
    var showsCity = false
    var showsDay = false
    var size: CGFloat = 11

    var body: some View {
        Group {
            if let forecast = controller.forecast, let place = controller.place {
                // Narrow spots drop the city first, then the day overview,
                // so the temperature is never truncated.
                ViewThatFits(in: .horizontal) {
                    row(forecast, place: place, city: showsCity, day: showsDay)
                    row(forecast, place: place, city: false, day: showsDay)
                    row(forecast, place: place, city: false, day: false)
                }
                .help(controller.summary ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(controller.summary ?? "Weather")
            }
        }
        .weatherVisible(controller)
    }

    private func row(_ forecast: WeatherForecast, place: WeatherPlace, city: Bool, day: Bool) -> some View {
        HStack(spacing: 3) {
            WeatherGlyph(code: forecast.current.code, isDay: forecast.current.isDay, size: size)
            Text(controller.temperature(forecast.current.temperature))
                .font(.system(size: size, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
                .fixedSize()
            if day, let today = forecast.day(containing: Date()) {
                Text("\(controller.temperature(today.high)) / \(controller.temperature(today.low))")
                    .font(.system(size: size - 1.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize()
                if today.precipitationProbability >= WeatherFormat.rainShownFrom {
                    HStack(spacing: 1) {
                        Image(systemName: "drop.fill").font(.system(size: size - 3.5, weight: .semibold))
                        Text("\(today.precipitationProbability)%")
                            .font(.system(size: size - 1.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(WeatherFormat.rainColor)
                    .fixedSize()
                }
            }
            if city {
                Text(place.name)
                    .font(.system(size: size - 1.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize()
            }
        }
    }
}

/// Day overview for Home (56×56, where the volume knob sits): symbol and
/// now, high / low, and the rain chance. Click opens Today › Weather.
/// Nothing (no network either) until a city is chosen.
struct WeatherHomeGlance: View {
    @ObservedObject var controller: WeatherController = .shared

    var body: some View {
        Button {
            PlannerRouter.shared.show(.weather)
        } label: {
            VStack(spacing: 2) {
                if let forecast = controller.forecast {
                    HStack(spacing: 1) {
                        WeatherGlyph(code: forecast.current.code, isDay: forecast.current.isDay, size: 12)
                        Text(controller.temperature(forecast.current.temperature))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(SparkVTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if let today = forecast.day(containing: Date()) {
                        Text("\(controller.temperature(today.high)) / \(controller.temperature(today.low))")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        HStack(spacing: 1.5) {
                            Image(systemName: "drop.fill").font(.system(size: 7, weight: .semibold))
                            Text("\(today.precipitationProbability)%")
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(today.precipitationProbability >= WeatherFormat.rainShownFrom
                                         ? WeatherFormat.rainColor : SparkVTheme.textTertiary)
                    }
                } else {
                    // A city is set; the first forecast is on its way.
                    Image(systemName: "cloud")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SparkVTheme.textTertiary)
                    Text(controller.place?.name ?? "Weather")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .weatherVisible(controller)
        .help(controller.summary.map { "\($0). Click for the forecast." } ?? "Weather")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.summary ?? "Weather")
        .accessibilityHint("Opens the forecast")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - City editor

/// Search a city, pick units, turn weather off. Searching sends what is
/// typed (nothing else) to Open-Meteo's geocoding service.
struct WeatherCityEditor: View {
    @ObservedObject var controller: WeatherController = .shared
    /// Off where a native units picker sits next to it (Settings).
    var showsUnits = true
    /// What leaves the Mac. Off only where the same words sit just above.
    var showsDisclosure = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let place = controller.place {
                    WidgetChip(title: place.name, detail: place.countryCode, symbol: "xmark", tint: WidgetKind.weather.tint,
                               help: "Turn weather off (forget \(place.name))") {
                        controller.setPlace(nil)
                    }
                } else {
                    Text("No city yet")
                        .font(.system(size: 9.5))
                        .foregroundStyle(WidgetStyle.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if showsUnits {
                    ForEach(WeatherUnits.allCases) { unit in
                        WidgetChip(title: unit == .automatic ? "Auto" : (unit == .celsius ? "°C" : "°F"),
                                   tint: WidgetKind.weather.tint, isOn: controller.units == unit,
                                   help: unit.title) { controller.units = unit }
                    }
                }
            }
            .frame(height: 20)

            HStack(spacing: 6) {
                WidgetSearchField(placeholder: controller.place == nil ? "Type a city" : "Change city", text: $controller.query,
                                  symbol: "location.magnifyingglass") {
                    if let first = controller.results.first { controller.setPlace(first) }
                }
                .frame(width: 150)
                if controller.isSearching {
                    ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if let message = controller.searchMessage {
                            Text(message).font(.system(size: 9.5)).foregroundStyle(WidgetStyle.tertiaryText)
                        }
                        ForEach(controller.results) { place in
                            WidgetChip(title: place.name, detail: place.countryCode, symbol: "plus", tint: WidgetKind.weather.tint,
                                       help: [place.name, place.detail].filter { !$0.isEmpty }.joined(separator: ", ")) {
                                controller.setPlace(place)
                            }
                        }
                    }
                }
            }
            .frame(height: 20)

            if showsDisclosure {
                Text(WeatherFormat.disclosure)
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetStyle.tertiaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
