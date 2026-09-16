require "test_helper"

class Ingestion::SecurityResolverTest < ActiveSupport::TestCase
  test "ticker-only identity preserves an existing security on a named exchange" do
    security = securities(:aapl)
    page = holding_page(ticker: security.ticker, lookup: "ticker_only")
    assert_no_difference "Security.count" do
      resolved = Ingestion::SecurityResolver.new.resolve(page)
      assert_equal security.id, resolved.fetch([ "holding", "position" ]).id
    end
  end

  test "offline fallback does not downgrade an existing market-data security" do
    security = Security.create!(ticker: "LOCAL_EXISTING", offline: false, name: "Existing name")
    page = holding_page(ticker: security.ticker, offline: true, name: "New source name")
    resolved = Ingestion::SecurityResolver.new.resolve(page)

    assert_equal security.id, resolved.fetch([ "holding", "position" ]).id
    assert_not security.reload.offline?
    assert_equal "Existing name", security.name
  end

  test "ticker-only creation preserves trading MIC separately from operating MIC" do
    page = holding_page(ticker: "INDEXA_NEW_ISIN", lookup: "ticker_only", name: "Index fund", exchange_mic: "XABC", country_code: "GB")
    security = Ingestion::SecurityResolver.new.resolve(page).fetch([ "holding", "position" ])
    assert_equal "XABC", security.exchange_mic
    assert_nil security.exchange_operating_mic
    assert_equal "GB", security.country_code
  end

  test "fallback ticker lookup reuses an existing security without changing its exchange" do
    security = Security.create!(ticker: "CRYPTO:FALLBACK", exchange_operating_mic: "XOLD", offline: false, name: "Existing")
    Security::Resolver.any_instance.expects(:resolve).raises(StandardError)
    page = holding_page(ticker: security.ticker, fallback_offline: true, fallback_lookup: "ticker_only",
      fallback_exchange_operating_mic: "XCBS", name: "Source name")
    assert_no_difference "Security.count" do
      assert_equal security.id, Ingestion::SecurityResolver.new.resolve(page).fetch([ "holding", "position" ]).id
    end
    assert_equal "XOLD", security.reload.exchange_operating_mic
    assert_equal "Existing", security.name
    assert_not security.offline?
  end

  test "fallback exchange applies only when primary resolution fails and a security must be created" do
    resolver = mock
    resolver.expects(:resolve).raises(StandardError)
    Security::Resolver.expects(:new).with("CRYPTO:NEW_FALLBACK", exchange_operating_mic: nil, country_code: nil).returns(resolver)
    page = holding_page(ticker: "CRYPTO:NEW_FALLBACK", fallback_offline: true, fallback_lookup: "ticker_only",
      fallback_exchange_operating_mic: "XCBS", name: "New crypto")
    security = Ingestion::SecurityResolver.new.resolve(page).fetch([ "holding", "position" ])
    assert_equal "XCBS", security.exchange_operating_mic
    assert security.offline?
  end

  test "ticker-only metadata cannot create an alternate MIC security or rename a healthy existing security" do
    security = securities(:aapl)
    page = holding_page(ticker: " aapl ", lookup: "ticker_only", name: "Source name", exchange_mic: "DIFFERENT",
      exchange_operating_mic: "XOTHER", country_code: "CA", repair_malformed_name: true)
    assert_no_difference "Security.count" do
      resolved = Ingestion::SecurityResolver.new.resolve(page).fetch([ "holding", "position" ])
      assert_equal security.id, resolved.id
    end
    assert_equal "Apple", security.reload.name
    assert_equal "XNAS", security.exchange_operating_mic
    assert_equal "US", security.country_code
  end

  test "malformed legacy security name repair requires an explicit descriptor flag" do
    security = Security.create!(ticker: "INDEXA_BAD_NAME", name: '{"bad":"legacy"}')
    page = holding_page(ticker: security.ticker, lookup: "ticker_only", name: "Readable name")
    Ingestion::SecurityResolver.new.resolve(page)
    assert_equal '{"bad":"legacy"}', security.reload.name
    fixed = holding_page(ticker: security.ticker, lookup: "ticker_only", name: "Readable name", repair_malformed_name: true)
    Ingestion::SecurityResolver.new.resolve(fixed)
    assert_equal "Readable name", security.reload.name
  end

  test "cash positions resolve within the linked financial account" do
    account = accounts(:investment)
    page = holding_page(lookup: "account_cash", currency: "USD")
    security = Ingestion::SecurityResolver.new(account: account).resolve(page).fetch([ "holding", "position" ])
    assert_equal Security.cash_for(account, currency: "USD").id, security.id
    assert security.cash?
    assert_not_equal Security.cash_for(accounts(:depository), currency: "USD").id, security.id
  end

  test "cash descriptors cannot choose an account or a different monetary currency" do
    assert_raises(Provider::AccountData::InvalidResponse) do
      Ingestion::SecurityResolver.new.resolve(holding_page(lookup: "account_cash", currency: "USD"))
    end
    assert_raises(Provider::AccountData::InvalidResponse) do
      Ingestion::SecurityResolver.new(account: accounts(:investment)).resolve(holding_page(lookup: "account_cash", currency: "CAD"))
    end
  end

  private
    def holding_page(**security)
      record = Ingestion::Record.holding(external_id: "position", currency: "USD", date: Date.current,
        quantity: BigDecimal("1"), security: security)
      Provider::AccountData::Page.new(records: [ record ], complete: true)
    end
end
