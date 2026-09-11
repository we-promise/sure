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

  test "institution_reports_total_basis? matches Vanguard, Fidelity, and Schwab org metadata" do
    cases = {
      { "name" => "Vanguard" }                          => true,
      { "name" => "VANGUARD BROKERAGE" }                => true,
      { "name" => "Fidelity Investments" }              => true,
      { "domain" => "vanguard.com" }                    => true,
      { "domain" => "401k.fidelity.com" }               => true,
      { "name" => "Charles Schwab", "domain" => "schwab.com" } => true,
      { "name" => "Chase" }                             => false,
      {}                                                => false
    }

    cases.each do |org, expected|
      account = Struct.new(:org_data).new(org)
      processor = SimplefinAccount::Investments::HoldingsProcessor.new(account)
      assert_equal expected,
        processor.send(:institution_reports_total_basis?),
        "org_data #{org.inspect} expected #{expected}"
    end
  end

  test "cost_basis from Charles Schwab is divided by qty (#2626)" do
    # Schwab reports `cost_basis` as the total position cost, not per-share,
    # in violation of the SimpleFIN spec — same failure mode as Vanguard
    # (#1182) and Fidelity (#1718). Observed on two independent Sure
    # instances via raw SimpleFIN payloads, e.g.:
    #   { "shares" => "651.00", "cost_basis" => "30162.36", "purchase_price" => "46.33235" }
    # Left uncorrected, Holding#calculate_trend later multiplies this
    # (mislabeled-as-per-share) total by qty again when reconstructing the
    # position's original cost, inflating a holding's unrealized loss by
    # roughly qty× — e.g. a $46,950 position showing a -99.8% / -$19.6M
    # "return" instead of its true +55.7% gain.
    cost_basis = @processor.send(
      :normalize_cost_basis,
      BigDecimal("30162.36"),
      BigDecimal("651"),
      "cost_basis",
      true # institution_reports_total_basis?
    )

    assert_in_delta 46.33, cost_basis.to_f, 0.01
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
