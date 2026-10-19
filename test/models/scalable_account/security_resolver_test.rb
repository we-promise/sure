require "test_helper"

class ScalableAccount::SecurityResolverTest < ActiveSupport::TestCase
  test "does not guess an exchange listing when an ISIN has several MICs" do
    Security.create!(ticker: isin, name: "Apple NASDAQ", exchange_operating_mic: "XNAS")
    Security.create!(ticker: isin, name: "Apple Xetra", exchange_operating_mic: "XETR")

    security = ScalableAccount::SecurityResolver.new.resolve(position)

    assert_equal isin, security.ticker
    assert_nil security.exchange_operating_mic
    assert security.offline?
    assert_equal "scalable_isin", security.offline_reason
  end

  test "reuses an existing exact blank-MIC ISIN security" do
    existing = Security.create!(ticker: isin, name: "Saved ISIN security", exchange_operating_mic: nil,
      offline: true, offline_reason: "manual")

    assert_equal existing, ScalableAccount::SecurityResolver.new.resolve(position)
  end

  private

    def isin
      "US0378331005"
    end

    def position
      ScalableItem::PortfolioNormalizer::Position.new(
        isin: isin,
        name: "Synthetic Apple security",
        security_type: "EQUITY",
        quantity: BigDecimal("1"),
        valuation: BigDecimal("10"),
        currency: "EUR",
        unit_price: BigDecimal("10"),
        fifo_price: nil,
        quote_metadata: {}
      )
    end
end
