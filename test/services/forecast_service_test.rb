require "test_helper"

class ForecastServiceTest < ActiveSupport::TestCase
  ADDRESS = "1600 Pennsylvania Ave NW, Washington, DC".freeze

  setup { @service = ForecastService.new }

  test "returns the current temperature, high/low and extended forecast for the address's zip code" do
    stub_geocode
    stub_forecast

    result = @service.call(ADDRESS)

    assert_equal "20500", result[:zip]
    assert_match "Washington", result[:location]
    assert_equal 62, result[:current_temperature]
    assert_equal "Partly cloudy", result[:current_description]
    assert_equal 64, result[:high]
    assert_equal 47, result[:low]
    assert_equal "°F", result[:units]
    assert_equal 3, result[:daily].size
    assert_equal({ date: Date.new(2026, 11, 1), high: 58, low: 46, description: "Light rain" }, result[:daily].second)
    assert_not result[:cached]
  end

  test "requests Fahrenheit for US addresses and Celsius elsewhere" do
    stub_geocode(body: [ { lat: "51.5", lon: "-0.12", display_name: "London", address: { postcode: "SW1A 2AA", country_code: "gb" } } ].to_json)
    stub_forecast

    result = @service.call("10 Downing Street, London")

    assert_equal "°C", result[:units]
    assert_equal "SW1A 2AA", result[:zip]
    assert_requested :get, ForecastStubs::FORECAST_URL, query: hash_including("temperature_unit" => "celsius")
  end

  test "serves repeat requests for the same zip code from cache for 30 minutes" do
    with_memory_cache do
      stub_geocode
      stub_forecast

      assert_not @service.call(ADDRESS)[:cached]
      assert @service.call(ADDRESS)[:cached]
      assert_requested :get, ForecastStubs::FORECAST_URL, times: 1

      travel 31.minutes do
        assert_not @service.call(ADDRESS)[:cached]
      end
      assert_requested :get, ForecastStubs::FORECAST_URL, times: 2
    end
  end

  test "different addresses in the same zip code share one cache entry" do
    with_memory_cache do
      stub_geocode
      stub_forecast

      @service.call(ADDRESS)
      assert @service.call("The White House, Washington DC")[:cached]
      assert_requested :get, ForecastStubs::FORECAST_URL, times: 1
    end
  end

  test "rejects a blank or overly long address without calling any API" do
    assert_raises(ForecastService::InvalidAddress) { @service.call("   ") }
    assert_raises(ForecastService::InvalidAddress) { @service.call("a" * 201) }
    assert_not_requested :get, ForecastStubs::GEOCODE_URL
  end

  test "raises InvalidAddress when the address can't be found" do
    stub_geocode(body: "[]")

    error = assert_raises(ForecastService::InvalidAddress) { @service.call("nowhere at all") }
    assert_match "couldn't find", error.message
  end

  test "raises InvalidAddress when the address has no zip code" do
    stub_geocode(body: [ { lat: "40", lon: "-100", display_name: "Nebraska", address: { country_code: "us" } } ].to_json)

    error = assert_raises(ForecastService::InvalidAddress) { @service.call("Nebraska") }
    assert_match "zip code", error.message
  end

  test "raises Error on a timeout" do
    stub_request(:get, ForecastStubs::GEOCODE_URL).to_timeout

    error = assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
    assert_match "couldn't reach", error.message
  end

  test "raises Error on a DNS failure" do
    stub_geocode
    stub_request(:get, ForecastStubs::FORECAST_URL).to_raise(SocketError.new("getaddrinfo: nodename nor servname provided"))

    assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
  end

  test "raises Error when the upstream is rate limiting" do
    stub_geocode(body: "", status: 429)

    error = assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
    assert_match "busy", error.message
  end

  test "raises Error on a 5xx response" do
    stub_geocode
    stub_forecast(body: "Bad gateway", status: 502)

    error = assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
    assert_match "HTTP 502", error.message
  end

  test "raises Error on a non-JSON response" do
    stub_geocode
    stub_forecast(body: "<html>oops</html>")

    error = assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
    assert_match "unexpected response", error.message
  end

  test "raises Error when the JSON has an unexpected shape" do
    stub_geocode
    stub_forecast(body: { "current" => {} }.to_json)

    assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
  end

  test "raises Error when the geocoder returns an unexpected shape" do
    stub_geocode(body: { error: "Unable to geocode" }.to_json)

    assert_raises(ForecastService::Error) { @service.call(ADDRESS) }
  end

  test "does not cache failed lookups" do
    with_memory_cache do
      stub_geocode
      stub_forecast(status: 503, body: "")
      assert_raises(ForecastService::Error) { @service.call(ADDRESS) }

      stub_forecast
      assert_not @service.call(ADDRESS)[:cached]
    end
  end
end
