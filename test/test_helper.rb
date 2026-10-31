ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

WebMock.disable_net_connect!

module ForecastStubs
  GEOCODE_URL = %r{\Ahttps://nominatim\.openstreetmap\.org/search}
  FORECAST_URL = %r{\Ahttps://api\.open-meteo\.com/v1/forecast}

  def stub_geocode(body: file_fixture("nominatim_search.json").read, status: 200)
    stub_request(:get, GEOCODE_URL).to_return(status: status, body: body, headers: { "Content-Type" => "application/json" })
  end

  def stub_forecast(body: file_fixture("open_meteo_forecast.json").read, status: 200)
    stub_request(:get, FORECAST_URL).to_return(status: status, body: body, headers: { "Content-Type" => "application/json" })
  end

  # The test environment uses :null_store; swap in a real store for tests that exercise caching.
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    include ForecastStubs
  end
end
