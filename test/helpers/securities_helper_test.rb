require "test_helper"

class SecuritiesHelperTest < ActionView::TestCase
  setup do
    @security = securities(:aapl)
  end

  test "labels an unavailable provider" do
    @security.stubs(:price_source).returns(Security::PriceSource.new(provider: "tiingo", status: :unavailable))

    assert_equal "Tiingo (unavailable)", security_price_source_label(@security)
  end

  test "labels an offline provider" do
    @security.stubs(:price_source).returns(Security::PriceSource.new(provider: "twelve_data", status: :offline))

    assert_equal "Twelve Data (paused)", security_price_source_label(@security)
  end

  test "humanizes a provider without a translated name" do
    @security.stubs(:price_source).returns(Security::PriceSource.new(provider: "some_new_source", status: :assigned))

    assert_equal "Some new source", security_price_source_label(@security)
  end

  test "names a missing provider as unknown" do
    assert_equal "Unknown", security_price_provider_name(nil)
  end

  test "has a translated name for every price provider" do
    Security.valid_price_providers.each do |key|
      assert I18n.exists?("securities.providers.#{key}", :en), "missing securities.providers.#{key}"
    end
  end
end
