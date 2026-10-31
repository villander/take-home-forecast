require "net/http"

# Looks up the weather forecast for a free-form address.
#
#   1. Geocode the address (Nominatim / OpenStreetMap) to get its zip code and coordinates.
#   2. Fetch the forecast (Open-Meteo) and cache it by zip code for 30 minutes.
#
# Both APIs are free and need no API key. Every upstream failure (timeouts, DNS errors,
# rate limits, 5xx, unparseable bodies) is raised as a ForecastService::Error with a
# message that is safe to show to the user.
class ForecastService
  class Error < StandardError; end
  class InvalidAddress < Error; end

  FORECAST_TTL = 30.minutes
  GEOCODE_TTL = 1.day
  MAX_ADDRESS_LENGTH = 200

  GEOCODE_URL = "https://nominatim.openstreetmap.org/search".freeze
  FORECAST_URL = "https://api.open-meteo.com/v1/forecast".freeze
  USER_AGENT = ENV.fetch("FORECAST_USER_AGENT", "weather-forecast-rails/1.0 (take-home exercise)")
  OPEN_TIMEOUT = 3 # seconds
  READ_TIMEOUT = 5 # seconds

  NETWORK_ERRORS = [ Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError ].freeze

  # WMO weather interpretation codes used by Open-Meteo.
  WEATHER_CODES = {
    0 => "Clear sky", 1 => "Mainly clear", 2 => "Partly cloudy", 3 => "Overcast",
    45 => "Fog", 48 => "Rime fog",
    51 => "Light drizzle", 53 => "Drizzle", 55 => "Dense drizzle", 56 => "Freezing drizzle", 57 => "Freezing drizzle",
    61 => "Light rain", 63 => "Rain", 65 => "Heavy rain", 66 => "Freezing rain", 67 => "Freezing rain",
    71 => "Light snow", 73 => "Snow", 75 => "Heavy snow", 77 => "Snow grains",
    80 => "Rain showers", 81 => "Rain showers", 82 => "Violent rain showers",
    85 => "Snow showers", 86 => "Heavy snow showers",
    95 => "Thunderstorm", 96 => "Thunderstorm with hail", 99 => "Thunderstorm with hail"
  }.freeze

  def call(address)
    address = address.to_s.squish
    raise InvalidAddress, "Please enter an address." if address.empty?
    raise InvalidAddress, "Address is too long (max #{MAX_ADDRESS_LENGTH} characters)." if address.length > MAX_ADDRESS_LENGTH

    location = geocode(address)

    cached = true
    forecast = Rails.cache.fetch(forecast_cache_key(location), expires_in: FORECAST_TTL, race_condition_ttl: 10.seconds) do
      cached = false
      fetch_forecast(location)
    end

    forecast.merge(location: location[:name], zip: location[:zip], cached: cached)
  end

  private
    def forecast_cache_key(location)
      "forecast/v1/#{location[:country]}/#{location[:zip]}"
    end

    def geocode(address)
      Rails.cache.fetch("geocode/v1/#{Digest::SHA256.hexdigest(address.downcase)}", expires_in: GEOCODE_TTL) do
        results = get_json(GEOCODE_URL, q: address, format: "jsonv2", addressdetails: 1, limit: 1)
        result = Array(results).first
        raise InvalidAddress, "We couldn't find that address." unless result

        zip = result.dig("address", "postcode").to_s.split(/[;,]/).first.to_s.strip
        raise InvalidAddress, "We couldn't determine a zip code for that address. Try a more specific address." if zip.empty?

        {
          name: result.fetch("display_name"),
          zip: zip.upcase,
          country: result.dig("address", "country_code").to_s.downcase,
          lat: Float(result.fetch("lat")),
          lon: Float(result.fetch("lon"))
        }
      end
    rescue KeyError, TypeError, ArgumentError
      raise Error, "The geocoding service returned an unexpected response."
    end

    def fetch_forecast(location)
      unit = location[:country] == "us" ? "fahrenheit" : "celsius"
      data = get_json(FORECAST_URL,
        latitude: location[:lat], longitude: location[:lon],
        current: "temperature_2m,weather_code",
        daily: "weather_code,temperature_2m_max,temperature_2m_min",
        temperature_unit: unit, timezone: "auto", forecast_days: 7)

      current = data.fetch("current")
      daily = data.fetch("daily")
      days = daily.fetch("time").each_with_index.map do |date, i|
        {
          date: Date.parse(date),
          high: daily.fetch("temperature_2m_max")[i]&.round,
          low: daily.fetch("temperature_2m_min")[i]&.round,
          description: WEATHER_CODES[daily.fetch("weather_code")[i]]
        }
      end

      {
        units: unit == "fahrenheit" ? "°F" : "°C",
        current_temperature: Float(current.fetch("temperature_2m")).round,
        current_description: WEATHER_CODES[current["weather_code"]],
        high: days.first&.dig(:high),
        low: days.first&.dig(:low),
        daily: days,
        fetched_at: Time.current
      }
    rescue KeyError, TypeError, ArgumentError, NoMethodError, Date::Error
      raise Error, "The weather service returned an unexpected response."
    end

    def get_json(url, params)
      uri = URI(url)
      uri.query = URI.encode_www_form(params)

      # max_retries: 0 turns off Net::HTTP's implicit retry so the timeouts are a real upper bound.
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, max_retries: 0) do |http|
        http.get(uri.request_uri, "User-Agent" => USER_AGENT, "Accept" => "application/json")
      end

      raise Error, "The weather service is busy right now. Please try again in a minute." if response.code == "429"
      raise Error, "The weather service is unavailable right now (HTTP #{response.code}). Please try again later." unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue *NETWORK_ERRORS => e
      Rails.logger.warn("[ForecastService] #{uri.host} request failed: #{e.class}: #{e.message}")
      raise Error, "We couldn't reach the weather service. Please try again later."
    rescue JSON::ParserError
      raise Error, "The weather service returned an unexpected response."
    end
end
