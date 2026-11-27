require "test_helper"

class SecuritiesHelperTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @security = securities(:aapl)
    @security.stubs(:current_price).returns(Money.new(200, "USD"))
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

  test "has a name for every price provider in each locale that lists provider names" do
    locales = I18n.available_locales.select do |locale|
      I18n.exists?("settings.hostings.provider_selection.providers", locale: locale, fallback: false)
    end
    assert_includes locales, :en

    locales.each do |locale|
      Security.valid_price_providers.each do |key|
        assert I18n.exists?("settings.hostings.provider_selection.providers.#{key}", locale: locale, fallback: false),
          "missing #{locale}.settings.hostings.provider_selection.providers.#{key}"
      end
    end
  end

  test "falls back to the English provider name in a locale without provider names" do
    I18n.with_locale(:nb) do
      assert_equal "Twelve Data", security_price_provider_name("twelve_data")
    end
  end

  test "shows the converted price with the quote beside it" do
    @security.stubs(:current_price_in).with("EUR").returns(Money.new(180, "EUR"))

    html = current_price_with_quote(@security, "EUR")

    assert_includes html, Money.new(180, "EUR").format
    assert_includes html, "(#{Money.new(200, "USD").format})"
  end

  test "shows only the quote when it is in the currency asked for" do
    @security.stubs(:current_price_in).with("USD").returns(Money.new(200, "USD"))

    assert_equal Money.new(200, "USD").format, current_price_with_quote(@security, "USD")
  end

  test "shows only the quote, under its own currency, without a rate" do
    @security.stubs(:current_price_in).with("EUR").returns(nil)

    assert_equal Money.new(200, "USD").format, current_price_with_quote(@security, "EUR")
  end

  test "shows nothing without a quote" do
    @security.stubs(:current_price).returns(nil)

    assert_nil current_price_with_quote(@security, "EUR")
  end
end
