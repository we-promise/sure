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

  test "crypto_base_asset strips the display-currency suffix" do
    %w[USD EUR JPY BRL TRY].each do |quote|
      sec = Security.new(ticker: "BTC#{quote}", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
      assert_equal "BTC", sec.crypto_base_asset, "expected BTC#{quote} -> BTC"
    end
  end

  test "crypto_base_asset returns nil for non-crypto securities" do
    sec = Security.new(ticker: "AAPL", exchange_operating_mic: "XNAS")
    assert_nil sec.crypto_base_asset
  end

  test "brandfetch_crypto_url uses the /crypto/ route and current size setting" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    assert_equal(
      "https://cdn.brandfetch.io/crypto/BTC/icon/fallback/lettermark/w/120/h/120?c=test-client-id",
      Security.brandfetch_crypto_url("BTC")
    )
  end

  test "brandfetch_crypto_url returns nil when Brandfetch is not configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    assert_nil Security.brandfetch_crypto_url("BTC")
  end

  test "display_logo_url for crypto returns the /crypto/{base} Brandfetch URL" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    sec = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC
    )

    assert_equal(
      "https://cdn.brandfetch.io/crypto/BTC/icon/fallback/lettermark/w/120/h/120?c=test-client-id",
      sec.display_logo_url
    )
  end

  test "display_logo_url for crypto falls back to stored logo_url when Brandfetch is disabled" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    sec = Security.new(
      ticker: "BTCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      logo_url: "https://example.com/btc.png"
    )

    assert_equal "https://example.com/btc.png", sec.display_logo_url
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

  test "before_save writes the /crypto/{base} URL to logo_url for new crypto securities" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    sec = Security.create!(
      ticker: "BTCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC
    )

    assert_equal(
      "https://cdn.brandfetch.io/crypto/BTC/icon/fallback/lettermark/w/120/h/120?c=test-client-id",
      sec.logo_url
    )
  end
end
