import Foundation

/// What the weather was, for the day being written about.
///
/// ## Why this is the hardest feature in the product to justify
///
/// Everything else Memoir knows is already on the machine. The weather is not, and there is no
/// version of this that reads it locally: macOS keeps no such store, and the Weather app's
/// data is not readable by anything else. Asking what the weather was means asking somebody,
/// and telling them roughly where you are.
///
/// That makes this the **third** outbound path in a product whose privacy policy is built on
/// there being two. So it is built the way the other two are, and the shape of that is the
/// whole design:
///
/// - **Its own switch, off by default.** `allowWeather`, beside `allowCloud` and
///   `allowLocalNetwork`. Nothing here runs until somebody turns it on, and the privacy table
///   grows a third row rather than an exception.
/// - **Counted at the send site.** `OutboundMonitor`, the same counter as the cloud brains, so
///   Settings → Data shows it like anything else. A request that does not appear in the
///   counter is the thing the counter exists to make impossible.
/// - **Coarse on purpose.** The coordinate is rounded to ``gridStep`` before it leaves (about
///   eleven kilometres). Weather does not vary across a street, so the precision is worth
///   nothing to the forecast and quite a lot to whoever is receiving it.
/// - **Nothing about you goes with it.** No identifier, no account, no key, no user agent that
///   says who this is. A date and a rounded coordinate.
///
/// ## Why Open-Meteo
///
/// It needs no account and no API key, which means there is nothing to sign up for, nothing to
/// revoke, and no credential in the build. Apple's WeatherKit would send the same coordinate to
/// Apple instead, requires the capability to be enabled against the App ID before a single
/// request works, and obliges the app to display Apple's attribution. The privacy difference
/// between the two is smaller than it looks: both are a third party learning roughly where
/// somebody was on a date.
public enum Weather {

    /// How coarse a coordinate goes out. 0.1° is roughly 11 km of latitude.
    ///
    /// Chosen so the answer is unchanged and the question is much less revealing. The weather
    /// at a neighbourhood's resolution and at a city's resolution are the same weather.
    public static let gridStep = 0.1

    /// What one day's weather was. Deliberately small: a word and two numbers is what a
    /// journal tile can hold, and everything else would be data collected for its own sake.
    public struct Day: Sendable, Equatable {
        /// The user-facing description, already in plain words: "overcast", "light rain".
        public let summary: String
        public let highCelsius: Double
        public let lowCelsius: Double

        public init(summary: String, highCelsius: Double, lowCelsius: Double) {
            self.summary = summary
            self.highCelsius = highCelsius
            self.lowCelsius = lowCelsius
        }
    }

    /// Rounds a coordinate onto the grid, which is the only form that ever leaves the machine.
    public static func coarsen(latitude: Double, longitude: Double) -> (lat: Double, lon: Double) {
        ((latitude / gridStep).rounded() * gridStep, (longitude / gridStep).rounded() * gridStep)
    }

    /// Asks what the weather was at a place on a day.
    ///
    /// - Parameter allowed: The `allowWeather` switch, passed in rather than read, so the
    ///   consent is visible at the call site and testable without a config file. False returns
    ///   nil and sends nothing, the same shape as `BrainRouter.isAllowed`.
    public static func forDay(
        _ day: Date,
        latitude: Double,
        longitude: Double,
        allowed: Bool,
        session: URLSession = .shared,
        calendar: Calendar = .current
    ) async -> Day? {
        guard allowed else { return nil }

        let coarse = coarsen(latitude: latitude, longitude: longitude)
        let stamp = DateFormatter()
        stamp.calendar = calendar
        stamp.timeZone = calendar.timeZone
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd"
        let date = stamp.string(from: day)

        // The forecast endpoint rather than the archive: the archive lags by days, and the day
        // somebody is writing about is almost always today or yesterday. `past_days` covers the
        // rest of the week the journal can reach.
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", coarse.lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", coarse.lon)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "start_date", value: date),
            URLQueryItem(name: "end_date", value: date),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url else { return nil }

        // Counted before the request goes, not after it succeeds. A failed request still left
        // the machine, the same reasoning `AnthropicBrain` records at its send site.
        OutboundMonitor.shared.record(destination: url.host ?? "open-meteo.com")

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.shared.warn("weather: unexpected response for \(date)")
                return nil
            }
            return decode(data)
        } catch {
            // A day without weather is a strip with one fewer tile. Never an error in the
            // user's face: nobody opened the journal to be told about a network.
            Log.shared.warn("weather: request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reads one day out of an Open-Meteo response.
    ///
    /// Separate from the request so the parsing is testable against a recorded body, which is
    /// the only way to test it without a network in the suite.
    public static func decode(_ data: Data) -> Day? {
        struct Response: Decodable {
            struct Daily: Decodable {
                let weather_code: [Int]
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
            }
            let daily: Daily
        }

        guard let parsed = try? JSONDecoder().decode(Response.self, from: data),
              let code = parsed.daily.weather_code.first,
              let high = parsed.daily.temperature_2m_max.first,
              let low = parsed.daily.temperature_2m_min.first
        else { return nil }

        return Day(summary: summary(forCode: code), highCelsius: high, lowCelsius: low)
    }

    /// WMO weather codes, in the words somebody would actually use.
    ///
    /// Grouped rather than transcribed. The standard distinguishes "moderate drizzle" from
    /// "dense drizzle", and a journal does not: what a tile needs is the word that would come
    /// out if you were asked what the day was like.
    public static func summary(forCode code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1, 2: return "some cloud"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 66, 80, 81: return "rain"
        case 65, 82: return "heavy rain"
        case 71, 73, 75, 77, 85, 86: return "snow"
        case 95, 96, 99: return "thunderstorms"
        default: return "unsettled"
        }
    }
}
