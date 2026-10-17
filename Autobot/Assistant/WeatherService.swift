// WeatherService.swift
// Short weather briefing from Open-Meteo (free, no API key or Apple developer account needed).
// Example: "It's 14 degrees and partly cloudy, with a high of 19 and a 40 percent chance of rain."

import CoreLocation
import Foundation

final class WeatherService {

    /// Returns a one-sentence briefing, or nil if the weather couldn't be fetched in time.
    func briefing(at location: CLLocation) async -> String? {
        guard let url = Self.forecastURL(for: location.coordinate) else { return nil }
        let request = URLRequest(url: url, timeoutInterval: AppConfig.Weather.requestTimeout)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let forecast = try JSONDecoder().decode(Forecast.self, from: data)
            return Self.sentence(for: forecast)
        } catch {
            print("Weather error:", error)
            return nil
        }
    }

    static var isMorning: Bool {
        AppConfig.Weather.morningHours.contains(Calendar.current.component(.hour, from: Date()))
    }

    // MARK: Request

    private static func forecastURL(for c: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", c.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", c.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        return components?.url
    }

    // MARK: Sentence

    private static func sentence(for f: Forecast) -> String {
        var text = "It's \(Int(f.current.temperature.rounded())) degrees and \(condition(for: f.current.weatherCode))"
        if let high = f.daily.maxTemperature.first {
            text += ", with a high of \(Int(high.rounded()))"
        }
        if let rain = f.daily.rainChance.first ?? nil, rain >= 30 {
            text += " and a \(rain) percent chance of rain"
        }
        return text + "."
    }

    /// WMO weather codes used by Open-Meteo.
    private static func condition(for code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzling"
        case 61...67: return "raining"
        case 71...77: return "snowing"
        case 80...82: return "showery"
        case 85, 86: return "snow showers"
        case 95...99: return "stormy"
        default: return "mixed"
        }
    }
}

// MARK: - Open-Meteo response

private nonisolated struct Forecast: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let weatherCode: Int
        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
    struct Daily: Decodable {
        let maxTemperature: [Double]
        let rainChance: [Int?]
        enum CodingKeys: String, CodingKey {
            case maxTemperature = "temperature_2m_max"
            case rainChance = "precipitation_probability_max"
        }
    }
    let current: Current
    let daily: Daily
}
