require "test_helper"

class Ingestion::OnchainSecurityResolverTest < ActiveSupport::TestCase
  test "canonical symbols reuse existing securities across MICs and bind only blank price providers" do
    security = Security.create!(ticker: "CRYPTO:ETH", name: "Existing ether", exchange_operating_mic: "XOLD", price_provider: nil)
    assert_no_difference "Security.count" do
      resolved = resolve(symbol: "WETH", ticker: "CRYPTO:ETH", name: "Wrapped ether")
      assert_equal security.id, resolved.id
    end
    assert_equal "binance_public", security.reload.price_provider
    assert_equal "XOLD", security.exchange_operating_mic
    assert_equal "Existing ether", security.name
  end

  test "existing explicit price provider is preserved and newly created asset gets crypto provider" do
    existing = Security.create!(ticker: "CRYPTO:USDC", name: "USD Coin", price_provider: "yahoo_finance")
    assert_equal existing.id, resolve(symbol: "USDC.e", ticker: "CRYPTO:USDC", name: "Bridged USDC").id
    assert_equal "yahoo_finance", existing.reload.price_provider
    created = resolve(symbol: "NEWCHAIN", ticker: "CRYPTO:NEWCHAIN", name: "New chain asset")
    assert_equal "binance_public", created.price_provider
    assert_equal Onchain::SecurityResolver::EXCHANGE_MIC, created.exchange_operating_mic
  end

  test "placeholder symbols mismatched tickers and extra identity hints are rejected before lookup" do
    Onchain::SecurityResolver.expects(:resolve).never
    assert_raises(Provider::AccountData::InvalidResponse) { resolve(symbol: "SPL:123…456", ticker: "CRYPTO:SOL", name: "Unverified token") }
    assert_raises(Provider::AccountData::InvalidResponse) { resolve(symbol: "ETH", ticker: "CRYPTO:BTC", name: "Ether") }
    assert_raises(Provider::AccountData::InvalidResponse) { resolve(symbol: "ETH", ticker: "CRYPTO:ETH", name: "Ether", price_provider: "arbitrary") }
  end

  private
    def resolve(**values)
      record = Ingestion::Record.holding(external_id: "position", date: Date.new(2026, 5, 8), currency: "USD", quantity: BigDecimal("1"),
        security: values.merge(lookup: "onchain_asset"))
      Ingestion::SecurityResolver.new.resolve(Provider::AccountData::Page.new(records: [ record ], complete: true)).fetch([ "holding", "position" ])
    end
end
