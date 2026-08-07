require "test_helper"

class SimplefinAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @processor = SimplefinAccount::Investments::HoldingsProcessor.new(
      OpenStruct.new(raw_holdings_payload: nil, current_account: nil)
    )
  end

  test "cost_basis source is used unchanged as per share basis" do
    payload = {
      "cost_basis" => "16.61",
      "total_cost" => "9588.61",
      "value" => "10108.16"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("16.61"), cost_basis
    assert_equal "cost_basis", source_key
  end

  test "basis source is used unchanged as per share basis" do
    payload = {
      "basis" => "16.61",
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("16.61"), cost_basis
    assert_equal "basis", source_key
  end

  test "total_cost source is normalized to per share basis" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("9588.61") / BigDecimal("577.279"), cost_basis
    assert_equal "total_cost", source_key
  end

  test "value source is normalized to per share basis" do
    payload = {
      "value" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_equal BigDecimal("9588.61") / BigDecimal("577.279"), cost_basis
    assert_equal "value", source_key
  end

  test "total cost source with zero quantity returns nil" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("0"), source_key)

    assert_nil cost_basis
    assert_equal "total_cost", source_key
  end

  test "total cost source with nil quantity returns nil" do
    payload = {
      "total_cost" => "9588.61"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, nil, source_key)

    assert_nil cost_basis
    assert_equal "total_cost", source_key
  end

  test "cost_basis from a known total-basis institution is divided by qty" do
    # Issue #1718 / #1182: Vanguard populates cost_basis with the total
    # position cost. When the institution is on the allowlist we divide.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("22004.40"),
      BigDecimal("139.00"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 158.30, cost_basis.to_f, 0.01
  end

  test "basis from a known total-basis institution is divided by qty" do
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("9000.00"),
      BigDecimal("200"),
      "basis",
      true
    )

    assert_equal BigDecimal("45.00"), cost_basis
  end

  test "cost_basis from a compliant institution is kept untouched (no false divide)" do
    # Codex regression: a legitimate per-share basis on a holding with a
    # large unrealized loss (e.g. $100/share basis now worth $5/share) must
    # NOT be divided by qty. Per the SimpleFIN spec, cost_basis is per-share
    # — only the institution allowlist should override that.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("100.00"),
      BigDecimal("100"),
      "cost_basis",
      false
    )

    assert_equal BigDecimal("100.00"), cost_basis
  end

  test "institution_reports_total_basis? matches Vanguard and Fidelity org metadata" do
    cases = {
      { "name" => "Vanguard" }                                 => true,
      { "name" => "VANGUARD BROKERAGE" }                       => true,
      { "name" => "Fidelity Investments" }                     => true,
      { "domain" => "vanguard.com" }                           => true,
      { "domain" => "401k.fidelity.com" }                      => true,
      { "name" => "Charles Schwab", "domain" => "schwab.com" } => false,
      { "name" => "Chase" }                                    => false,
      {}                                                       => false
    }

    cases.each do |org, expected|
      account = Struct.new(:org_data).new(org)
      processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)

      assert_equal expected,
        processor.send(:institution_reports_total_basis?),
        "org_data #{org.inspect} expected #{expected}"
    end
  end

  test "missing cost basis fields return nil" do
    payload = {
      "market_value" => "10108.16"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(:normalize_cost_basis, raw_cost_basis, BigDecimal("577.279"), source_key)

    assert_nil raw_cost_basis
    assert_nil source_key
    assert_nil cost_basis
  end

  test "aggregation_key returns upcased symbol" do
    assert_equal "AAPL-USD", @processor.send(:aggregation_key, { "symbol" => "aapl", "id" => "x", "currency" => "usd" })
  end

  test "aggregation_key returns __nosym_ key when symbol is nil" do
    assert_equal "__nosym_cash-1", @processor.send(:aggregation_key, { "symbol" => nil, "id" => "cash-1", "currency" => "USD" })
  end

  test "aggregation_key returns __nosym_ key when symbol is blank" do
    assert_equal "__nosym_cash-2", @processor.send(:aggregation_key, { "symbol" => "", "id" => "cash-2", "currency" => "USD" })
  end

  test "weighted_average_cost_basis returns nil when no lot has a basis" do
    lots = [ { "shares" => "5" }, { "shares" => "3" } ]
    assert_nil @processor.send(:weighted_average_cost_basis, lots, %w[shares])
  end

  test "weighted_average_cost_basis returns nil when total qty with basis is zero" do
    lots = [ { "shares" => "0", "cost_basis" => "100" } ]
    assert_nil @processor.send(:weighted_average_cost_basis, lots, %w[shares])
  end

  test "weighted_average_cost_basis computes per-share weighted average across lots" do
    lots = [
      { "shares" => "2", "cost_basis" => "10" },
      { "shares" => "3", "cost_basis" => "20" }
    ]
    result = @processor.send(:weighted_average_cost_basis, lots, %w[shares])
    assert_in_delta 16.0, result.to_f, 0.0001
  end

  test "weighted_average_cost_basis treats total_cost as an already-total value" do
    lots = [
      { "shares" => "4", "total_cost" => "100" },
      { "shares" => "4", "total_cost" => "100" }
    ]
    result = @processor.send(:weighted_average_cost_basis, lots, %w[shares])
    assert_in_delta 25.0, result.to_f, 0.0001
  end

  test "weighted_average_cost_basis skips lots without any basis key" do
    lots = [
      { "shares" => "5", "cost_basis" => "20" },
      { "shares" => "100" }
    ]
    result = @processor.send(:weighted_average_cost_basis, lots, %w[shares])
    assert_in_delta 20.0, result.to_f, 0.0001
  end

  test "holdings_data returns empty array when payload is nil" do
    account = OpenStruct.new(raw_holdings_payload: nil, current_account: nil)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)
    assert_equal [], processor.send(:holdings_data)
  end

  test "holdings_data aggregates multiple lots for the same symbol into one record" do
    raw = [
      { "id" => "lot-a", "symbol" => "VOO", "currency" => "USD", "shares" => "3", "market_value" => "900" },
      { "id" => "lot-b", "symbol" => "VOO", "currency" => "USD", "shares" => "7", "market_value" => "2100" }
    ]
    account = OpenStruct.new(raw_holdings_payload: raw, current_account: nil)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)

    result = processor.send(:holdings_data)

    assert_equal 1, result.size
    assert_equal "HOL-VOO-USD", result.first["id"]
    assert_in_delta 10.0, result.first["shares"].to_f, 0.0001
    assert_in_delta 3000.0, result.first["market_value"].to_f, 0.0001
  end

  test "holdings_data keeps distinct symbols as separate records" do
    raw = [
      { "id" => "a", "symbol" => "AAPL", "currency" => "USD", "shares" => "1", "market_value" => "150" },
      { "id" => "b", "symbol" => "GOOG", "currency" => "USD", "shares" => "2", "market_value" => "300" }
    ]
    account = OpenStruct.new(raw_holdings_payload: raw, current_account: nil)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)

    result = processor.send(:holdings_data)

    assert_equal 2, result.size
    assert_equal %w[HOL-AAPL-USD HOL-GOOG-USD], result.map { |h| h["id"] }.sort
  end

  test "holdings_data keeps same-symbol different-currency lots as separate records" do
    raw = [
      { "id" => "a", "symbol" => "AAPL", "currency" => "USD", "shares" => "1", "market_value" => "150" },
      { "id" => "b", "symbol" => "AAPL", "currency" => "GBP", "shares" => "2", "market_value" => "240" }
    ]
    account = OpenStruct.new(raw_holdings_payload: raw, current_account: nil)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)

    result = processor.send(:holdings_data)

    assert_equal 2, result.size
    assert_equal %w[HOL-AAPL-GBP HOL-AAPL-USD], result.map { |h| h["id"] }.sort
  end

  test "holdings_data does not aggregate symbolless lots" do
    raw = [
      { "id" => "cash-1", "symbol" => nil, "shares" => "1", "market_value" => "100" },
      { "id" => "cash-2", "symbol" => nil, "shares" => "1", "market_value" => "200" }
    ]
    account = OpenStruct.new(raw_holdings_payload: raw, current_account: nil)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)

    result = processor.send(:holdings_data)

    assert_equal 2, result.size
  end

  test "holdings_data skips malformed records that are not hashes" do
    raw = [
      nil,
      "unexpected string",
      { "id" => "a", "symbol" => "AAPL", "currency" => "USD", "shares" => "1", "market_value" => "150" }
    ]
    account = OpenStruct.new(raw_holdings_payload: raw, current_account: nil)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)

    result = processor.send(:holdings_data)

    assert_equal 1, result.size
    assert_equal "HOL-AAPL-USD", result.first["id"]
  end

  test "normalize_to_aggregate sets id to HOL-{SYMBOL:CURRENCY}" do
    lots = [ { "id" => "lot-1", "symbol" => "msft", "currency" => "USD", "shares" => "5", "market_value" => "500" } ]
    assert_equal "HOL-MSFT-USD", @processor.send(:normalize_to_aggregate, "MSFT-USD", lots)["id"]
  end

  test "normalize_to_aggregate removes qty alias keys after merge" do
    lots = [
      { "id" => "a", "symbol" => "QQQ", "currency" => "USD", "shares" => "2", "quantity" => "2", "qty" => "2", "units" => "2", "market_value" => "200" },
      { "id" => "b", "symbol" => "QQQ", "currency" => "USD", "shares" => "3", "quantity" => "3", "qty" => "3", "units" => "3", "market_value" => "300" }
    ]
    result = @processor.send(:normalize_to_aggregate, "QQQ-USD", lots)

    assert_nil result["quantity"]
    assert_nil result["qty"]
    assert_nil result["units"]
    assert result["shares"]
  end

  test "normalize_to_aggregate removes legacy cost basis alias keys" do
    lots = [ { "id" => "a", "symbol" => "F", "currency" => "USD", "shares" => "10", "market_value" => "100", "basis" => "80", "total_cost" => "80", "value" => "80" } ]
    result = @processor.send(:normalize_to_aggregate, "F-USD", lots)

    assert_nil result["basis"]
    assert_nil result["total_cost"]
    assert_nil result["value"]
  end

  test "normalize_to_aggregate omits cost_basis key when no basis data is present" do
    lots = [ { "id" => "a", "symbol" => "F", "currency" => "USD", "shares" => "5", "market_value" => "50" } ]
    assert_not @processor.send(:normalize_to_aggregate, "F-USD", lots).key?("cost_basis")
  end
end
