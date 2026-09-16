require "test_helper"

class SecurityTest < ActiveSupport::TestCase
  # Below has 3 example scenarios:
  # 1. Original ticker
  # 2. Duplicate ticker on a different exchange (different market price)
  # 3. "Offline" version of the same ticker (for users not connected to a provider)
  test "classification columns accept nil and every value in the taxonomy" do
    security = securities(:aapl)

    assert_nil security.asset_class
    assert_not security.classification_locked?

    Security::ASSET_CLASSES.each do |asset_class|
      security.asset_class = asset_class
      assert security.valid?, "#{asset_class} should be a valid asset_class"
    end
    Security::ASSET_SUB_CLASSES.each do |sub_class|
      security.asset_sub_class = sub_class
      assert security.valid?, "#{sub_class} should be a valid asset_sub_class"
    end
    Security::CLASSIFICATION_SOURCES.each do |source|
      security.classification_source = source
      assert security.valid?, "#{source} should be a valid classification_source"
    end
  end

  test "classification columns reject values outside the taxonomy" do
    security = securities(:aapl)

    security.asset_class = "stocks"
    assert_not security.valid?
    assert_includes security.errors[:asset_class], "is not included in the list"

    security.asset_class = nil
    security.asset_sub_class = "share"
    assert_not security.valid?

    security.asset_sub_class = nil
    security.classification_source = "guess"
    assert_not security.valid?
  end

  test "the database enforces the classification taxonomy independently of the model" do
    security = securities(:aapl)

    # update_column skips validations, so only the check constraint can object.
    # Each attempt runs in its own savepoint: a failed statement aborts the
    # surrounding transaction, which is the one the test fixture runs in.
    { asset_class: "stocks", asset_sub_class: "share", classification_source: "guess" }.each do |column, value|
      assert_raises(ActiveRecord::StatementInvalid, "#{column}=#{value} should violate the check constraint") do
        Security.transaction(requires_new: true) { security.update_column(column, value) }
      end
    end

    security.update_columns(asset_class: "equity", asset_sub_class: "stock", classification_source: "manual", classification_locked: true)
    assert_equal %w[equity stock manual], security.reload.values_at(:asset_class, :asset_sub_class, :classification_source)
    assert security.classification_locked?
  end

  test "the model taxonomy and the database constraint list the same values" do
    constraints = Security.connection.check_constraints(:securities).index_by(&:name)

    {
      "chk_securities_asset_class" => Security::ASSET_CLASSES,
      "chk_securities_asset_sub_class" => Security::ASSET_SUB_CLASSES,
      "chk_securities_classification_source" => Security::CLASSIFICATION_SOURCES
    }.each do |name, values|
      expression = constraints.fetch(name).expression
      assert_equal values.sort, expression.scan(/'([a-z_]+)'/).flatten.sort,
        "#{name} and the model constant have drifted apart"
    end
  end

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

  test "canonicalizes WAR to XWAR on save" do
    security = Security.create!(ticker: "KTY", exchange_operating_mic: "WAR")

    assert_equal "XWAR", security.exchange_operating_mic
  end

  test "find_by_ticker_and_exchange upgrades legacy WAR and avoids duplicates" do
    legacy = Security.create!(ticker: "KTY", exchange_operating_mic: "XWAR")
    legacy.update_columns(exchange_operating_mic: "WAR")

    found = Security.find_by_ticker_and_exchange(ticker: "KTY", exchange_operating_mic: "XWAR")

    assert_equal legacy.id, found.id
    assert_equal "XWAR", found.reload.exchange_operating_mic
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

  # The symbol lands in a URL path segment and comes from provider data — an
  # on-chain token can be called whatever its deployer chose. These would not
  # merely break the link: the slash points the path elsewhere on the CDN, and
  # the hash pushes the client id into a fragment Brandfetch never sees.
  test "brandfetch_crypto_url refuses a symbol carrying URL delimiters" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    [ "BTC/../ETH", "BTC?c=leak", "BTC#frag", "BTC ETH", "..", ".BTC", "BTC%2F" ].each do |symbol|
      assert_nil Security.brandfetch_crypto_url(symbol), "#{symbol.inspect} reached the URL"
    end
  end

  # Real tickers carry dots and dashes — USDC.e before canonicalisation, and
  # dashed pairs from some providers. The guard must not swallow them.
  test "brandfetch_crypto_url still accepts the punctuation real tickers use" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    [ "BTC", "USDC.E", "WSTETH", "1INCH", "BTC-B" ].each do |symbol|
      assert_not_nil Security.brandfetch_crypto_url(symbol), "#{symbol.inspect} was refused"
    end
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

  test "display_logo_url for non-crypto with no website prefers stored logo over brandfetch lettermark" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)

    sec = Security.new(
      ticker: "SBER",
      exchange_operating_mic: "MISX",
      logo_url: "https://invest-brands.cdn-tinkoff.ru/SBERx160.png"
    )

    assert_equal "https://invest-brands.cdn-tinkoff.ru/SBERx160.png", sec.display_logo_url
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

  # Every crypto integration stores the prefixed form — the on-chain wallets,
  # Kraken, CoinStats and Binance all write "CRYPTO:BTC" — and this answered nil
  # for all of them, so none of their securities carried a logo.
  test "resolves the base asset from a prefixed crypto ticker" do
    security = Security.new(ticker: "CRYPTO:BTC", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)

    assert_equal "BTC", security.crypto_base_asset
  end

  test "still resolves the pair form the search results produce" do
    security = Security.new(ticker: "BTCUSD", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)

    assert_equal "BTC", security.crypto_base_asset
  end

  test "a non-crypto security has no base asset" do
    security = Security.new(ticker: "AAPL", exchange_operating_mic: "XNAS")

    assert_nil security.crypto_base_asset
  end
end
