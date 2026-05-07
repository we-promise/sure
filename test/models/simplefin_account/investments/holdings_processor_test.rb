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
