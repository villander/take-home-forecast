require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  ADDRESS = "1600 Pennsylvania Ave NW, Washington, DC".freeze

  test "shows the address form" do
    get root_path

    assert_response :success
    assert_select "input[name=address]"
    assert_select ".forecast", count: 0
  end

  test "shows the forecast for an address" do
    stub_geocode
    stub_forecast

    get root_path, params: { address: ADDRESS }

    assert_response :success
    assert_select ".location", /20500/
    assert_select ".temperature", "62°F"
    assert_select ".high-low", /High 64°F/
    assert_select "tbody tr", 3
    assert_select ".badge.live"
  end

  test "shows a cache indicator when the forecast comes from cache" do
    with_memory_cache do
      stub_geocode
      stub_forecast

      get root_path, params: { address: ADDRESS }
      assert_select ".badge.live"

      get root_path, params: { address: ADDRESS }
      assert_select ".badge.cached", /From cache/
    end
  end

  test "shows a friendly error for an unknown address" do
    stub_geocode(body: "[]")

    get root_path, params: { address: "nowhere at all" }

    assert_response :unprocessable_entity
    assert_select ".error", /couldn't find/
  end

  test "shows a friendly error when the weather service is down" do
    stub_geocode
    stub_request(:get, ForecastStubs::FORECAST_URL).to_timeout

    get root_path, params: { address: ADDRESS }

    assert_response :service_unavailable
    assert_select ".error", /try again later/
    assert_select "input[name=address][value=?]", ADDRESS
  end
end
