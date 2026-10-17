require "test_helper"

class FinecoItem::PortfolioNormalizerTest < ActiveSupport::TestCase
  SUMMARY = {
    "currencyCd" => "EUR",
    "bookValue" => "90.00",
    "marketValue" => "100.00",
    "profitLoss" => "10.00",
    "profitLossPerc" => "11.11",
    "accrual" => "0.50"
  }.freeze

  POSITION = {
    "instrId" => "US0000000002",
    "venueSystem" => "XETRA",
    "symbol" => "SYNTH",
    "description" => "Synthetic fund",
    "type" => "etf",
    "currencyCd" => "EUR",
    "qty" => "2",
    "avgPrice" => "45",
    "marketPrice" => "50",
    "bookValue" => "90",
    "marketValue" => "100",
    "profitLoss" => "10",
    "accrual" => "0.50",
    "ongoingAccrual" => "0.25"
  }.freeze

  test "uses the EUR effective unit value and cost basis while preserving the original bond quote" do
    bond = POSITION.merge(
      "instrId" => "US0000000010",
      "venueSystem" => "ETLX",
      "type" => "bond",
      "currencyCd" => "GBP",
      "marketPrice" => "98.5"
    )
    payload = portfolio_payload(positions: [ bond ], summary: SUMMARY)

    snapshot = normalize(payload)
    position = snapshot.positions.first

    assert_equal "EUR", snapshot.currency
    assert_equal BigDecimal("100"), snapshot.market_value
    assert_equal "ETLX", position.mic
    assert_equal "GBP", position.quote_currency
    assert_equal BigDecimal("98.5"), position.quote_price
    assert_equal BigDecimal("50"), position.effective_price
    assert_equal BigDecimal("45"), position.cost_basis
    assert_equal BigDecimal("0.5"), position.accrual
    assert_equal BigDecimal("0.25"), position.ongoing_accrual
  end

  test "normalizes a complete empty portfolio to a zero EUR snapshot" do
    zero = SUMMARY.transform_values { |value| value == "EUR" ? value : "0" }

    snapshot = normalize(portfolio_payload(positions: [], summary: zero))

    assert_empty snapshot.positions
    assert_equal BigDecimal("0"), snapshot.market_value
    assert_equal "EUR", snapshot.currency
  end

  test "rejects unsupported instrument types, identities, and duplicate positions" do
    unsupported = POSITION.merge("type" => "option")
    assert_raises FinecoItem::PortfolioImportError do
      normalize(portfolio_payload(positions: [ unsupported ], summary: SUMMARY))
    end

    invalid_isin = POSITION.merge("instrId" => "US0000000001")
    assert_raises FinecoItem::PortfolioImportError do
      normalize(portfolio_payload(positions: [ invalid_isin ], summary: SUMMARY))
    end

    duplicate_identity = POSITION.merge("currencyCd" => "GBP")
    assert_raises FinecoItem::PortfolioImportError do
      normalize(portfolio_payload(positions: [ POSITION, duplicate_identity ], summary: SUMMARY))
    end

    same_isin_different_venue = POSITION.merge("venueSystem" => "ETLX")
    assert_raises FinecoItem::PortfolioImportError do
      normalize(portfolio_payload(positions: [ POSITION, same_isin_different_venue ], summary: SUMMARY))
    end
  end

  test "rejects incomplete and filtered snapshots before materialization" do
    unsupported_venue = POSITION.merge("venueSystem" => "UNKNOWN")
    assert_raises FinecoItem::PortfolioImportError do
      normalize(portfolio_payload(positions: [ unsupported_venue ], summary: SUMMARY))
    end

    partial = portfolio_payload(positions: [ POSITION ], summary: SUMMARY)
    partial["filters"]["currencies"]["total"] = %w[EUR GBP]
    assert_raises FinecoItem::PortfolioImportError do
      normalize(partial)
    end

    invalid_summary = portfolio_payload(positions: [ POSITION ], summary: SUMMARY)
    invalid_summary["summary"]["total"]["marketValue"] = "200"
    assert_raises FinecoItem::PortfolioImportError do
      normalize(invalid_summary)
    end
  end

  test "rejects zero quantity with nonzero market value instead of dropping it" do
    inconsistent = POSITION.merge("qty" => "0")

    assert_raises FinecoItem::PortfolioImportError do
      normalize(portfolio_payload(positions: [ inconsistent ], summary: SUMMARY))
    end
  end

  private

    def normalize(payload)
      FinecoItem::PortfolioNormalizer.new(payload: payload, captured_at: Time.zone.now).normalize
    end

    def portfolio_payload(positions:, summary:)
      currencies = positions.map { |position| position["currencyCd"] }.uniq.sort
      instrument_types = positions.map { |position| position["type"] }.uniq.sort
      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => currencies, "show" => currencies },
          "instrumentTypes" => { "total" => instrument_types, "show" => instrument_types }
        },
        "positions" => { "show" => positions.map(&:dup) },
        "summary" => { "show" => summary.dup, "total" => summary.dup }
      }
    end
end
