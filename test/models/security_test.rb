require "test_helper"

class SecurityTest < ActiveSupport::TestCase
  # Below has 3 example scenarios:
  # 1. Original ticker
  # 2. Duplicate ticker on a different exchange (different market price)
  # 3. "Offline" version of the same ticker (for users not connected to a provider)
  test "can have duplicate tickers if exchange is different" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.create!(ticker: "TEST", exchange_operating_mic: "CBOE")
    offline = Security.create!(ticker: "TEST", exchange_operating_mic: nil)

    assert original.valid?
    assert duplicate.valid?
    assert offline.valid?
  end

  test "cannot have duplicate tickers if exchange is the same" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: "XNAS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "cannot have duplicate tickers if exchange is nil" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: nil)
    duplicate = Security.new(ticker: "TEST", exchange_operating_mic: nil)

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "casing is ignored when checking for duplicates" do
    original = Security.create!(ticker: "TEST", exchange_operating_mic: "XNAS")
    duplicate = Security.new(ticker: "tEst", exchange_operating_mic: "xNaS")

    assert_not duplicate.valid?
    assert_equal [ "has already been taken" ], duplicate.errors[:ticker]
  end

  test "first_provider_price_on resets when price_provider changes" do
    sec = Security.create!(
      ticker: "TEST",
      exchange_operating_mic: "XNAS",
      price_provider: "twelve_data",
      first_provider_price_on: Date.parse("2020-01-03")
    )

    sec.update!(price_provider: "yahoo_finance")

    assert_nil sec.reload.first_provider_price_on
  end

  test "first_provider_price_on is preserved when unrelated fields change" do
    sec = Security.create!(
      ticker: "TEST",
      exchange_operating_mic: "XNAS",
      price_provider: "twelve_data",
      first_provider_price_on: Date.parse("2020-01-03"),
      offline: false
    )

    sec.update!(offline: true, failed_fetch_count: 3)

    assert_equal Date.parse("2020-01-03"), sec.reload.first_provider_price_on
  end

  test "first_provider_price_on respects explicit assignment alongside provider change" do
    sec = Security.create!(
      ticker: "TEST",
      exchange_operating_mic: "XNAS",
      price_provider: "twelve_data",
      first_provider_price_on: Date.parse("2020-01-03")
    )

    # Caller changes both in the same save — honor the explicit value.
    sec.update!(
      price_provider: "yahoo_finance",
      first_provider_price_on: Date.parse("2024-03-21")
    )

    assert_equal Date.parse("2024-03-21"), sec.reload.first_provider_price_on
  end

  test "cash_for lazily creates a per-account synthetic cash security" do
    account = accounts(:investment)

    cash = Security.cash_for(account)

    assert cash.persisted?
    assert cash.cash?
    assert cash.offline?
    assert_equal "Cash", cash.name
    assert_includes cash.ticker, account.id.upcase
  end

  test "cash_for returns the same security on repeated calls" do
    account = accounts(:investment)

    first  = Security.cash_for(account)
    second = Security.cash_for(account)

    assert_equal first.id, second.id
  end

  test "standard scope excludes cash securities" do
    account = accounts(:investment)
    Security.cash_for(account)

    standard_tickers = Security.standard.pluck(:ticker)

    assert_not_includes standard_tickers, "CASH-#{account.id.upcase}"
  end

  test "crypto? is true for Binance MIC and false otherwise" do
    crypto = Security.new(ticker: "BTCUSD", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    equity = Security.new(ticker: "AAPL",   exchange_operating_mic: "XNAS")
    offline = Security.new(ticker: "ACME",  exchange_operating_mic: nil)

    assert crypto.crypto?
    assert_not equity.crypto?
    assert_not offline.crypto?
  end

  test "display_logo_url for crypto prefers logo_url and falls back to brandfetch with binance.com" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    with_logo = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      logo_url: "https://cdn.jsdelivr.net/gh/lindomar-oliveira/binance-data-plus/assets/img/BTC.png"
    )
    assert_equal "https://cdn.jsdelivr.net/gh/lindomar-oliveira/binance-data-plus/assets/img/BTC.png",
                 with_logo.display_logo_url

    without_logo = Security.new(
      ticker: "NOPECOIN",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      logo_url: nil
    )
    assert_equal "https://cdn.brandfetch.io/binance.com/icon/fallback/lettermark/w/120/h/120?c=test-client-id",
                 without_logo.display_logo_url
  end

  test "display_logo_url for non-crypto prefers brandfetch over stored logo_url" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    sec = Security.new(
      ticker: "AAPL",
      exchange_operating_mic: "XNAS",
      logo_url: "https://example.com/aapl.png",
      website_url: "https://www.apple.com"
    )

    url = sec.display_logo_url
    assert_includes url, "cdn.brandfetch.io/apple.com"
  end

  test "display_logo_url for non-crypto falls back to logo_url when brandfetch is disabled" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    sec = Security.new(
      ticker: "AAPL",
      exchange_operating_mic: "XNAS",
      logo_url: "https://example.com/aapl.png"
    )

    assert_equal "https://example.com/aapl.png", sec.display_logo_url
  end
end
