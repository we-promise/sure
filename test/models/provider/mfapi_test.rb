require "test_helper"

class Provider::MfapiTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Mfapi.new
  end

  test "provider_name returns mfapi" do
    assert_equal "mfapi", @provider.provider_name
  end

  test "search_schemes returns schemes" do
    VCR.use_cassette("mfapi/search_schemes") do
      schemes = @provider.search_schemes("HDFC")

      assert schemes.is_a?(Array)
      assert schemes.first.is_a?(Provider::Mfapi::Scheme)
    end
  end

  test "fetch_latest_nav returns nav data" do
    VCR.use_cassette("mfapi/fetch_latest_nav") do
      nav_data = @provider.fetch_latest_nav("118532")

      assert nav_data.is_a?(Provider::Mfapi::NavData)
      assert_equal "118532", nav_data.scheme_code
      assert nav_data.nav > 0
      assert_equal "INR", nav_data.currency rescue nil
    end
  end

  test "fetch_nav_history returns price history" do
    VCR.use_cassette("mfapi/fetch_nav_history") do
      prices = @provider.fetch_nav_history("118532", start_date: 1.week.ago, end_date: Date.current)

      assert prices.is_a?(Array)
      assert prices.first.is_a?(Provider::Mfapi::Price) if prices.any?
    end
  end

  test "to_security converts scheme to security" do
    VCR.use_cassette("mfapi/to_security") do
      security = @provider.to_security("118532")

      assert security.is_a?(Provider::Mfapi::Security)
      assert_equal "118532", security.symbol
      assert_equal "IN", security.country_code
    end
  end

  test "healthy returns true when API is accessible" do
    VCR.use_cassette("mfapi/healthy") do
      assert @provider.healthy?
    end
  end
end
