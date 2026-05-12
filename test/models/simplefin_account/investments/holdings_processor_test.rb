require "test_helper"

class SimplefinAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)
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

  test "cost_basis reported as a total (Vanguard / Fidelity) is divided when market_value disagrees" do
    # Issue #1718 / #1182: Vanguard puts the total position cost in cost_basis.
    # Raw 22004.40 is two orders of magnitude above the ~$162 share price,
    # so the heuristic should recognize it as a total and divide by qty.
    payload = {
      "shares" => "139.00",
      "cost_basis" => "22004.40",
      "market_value" => "22626.42"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(
      :normalize_cost_basis,
      raw_cost_basis,
      BigDecimal("139.00"),
      source_key,
      BigDecimal("22626.42")
    )

    assert_in_delta 158.30, cost_basis.to_f, 0.01
    assert_equal "cost_basis", source_key
  end

  test "cost_basis reported as per-share is kept when market_value agrees" do
    # Brokerage correctly reports per-share basis ($45) for a $50 share price.
    # Heuristic must NOT divide this — that would produce a $0.45 phantom basis.
    payload = {
      "shares" => "100",
      "cost_basis" => "45.00",
      "market_value" => "5000.00"
    }

    raw_cost_basis, source_key = @processor.send(:cost_basis_from, payload)
    cost_basis = @processor.send(
      :normalize_cost_basis,
      raw_cost_basis,
      BigDecimal("100"),
      source_key,
      BigDecimal("5000.00")
    )

    assert_equal BigDecimal("45.00"), cost_basis
  end

  test "cost_basis heuristic falls back to per-share when market_value missing" do
    # No market_value → can't sanity-check. Preserve pre-fix behavior of
    # trusting the spec (treat as per-share) so we never regress a known-good
    # provider just because the market value happens to be absent.
    raw_cost_basis = BigDecimal("22004.40")
    cost_basis = @processor.send(
      :normalize_cost_basis,
      raw_cost_basis,
      BigDecimal("139.00"),
      "cost_basis",
      nil
    )

    assert_equal raw_cost_basis, cost_basis
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
end
