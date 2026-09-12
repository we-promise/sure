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

  test "lots of the same security combine into one position" do
    # SimpleFIN reports one record per lot. A 401k splitting employee deferral
    # from employer match sends two records for the same fund, and `holdings` is
    # uniquely indexed on (account_id, security_id, date, currency), so importing
    # them separately made the second overwrite the first.
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-b", "symbol" => "AAPL", "shares" => "11.891485", "market_value" => "3070.14", "cost_basis" => "200.00" },
      { "id" => "lot-a", "symbol" => "AAPL", "shares" => "2.378397",  "market_value" => "614.05",  "cost_basis" => "250.00" }
    ])
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)

    simplefin_account = stub(account_provider: nil)
    processor.stubs(:simplefin_account).returns(simplefin_account)

    # A plain recorder rather than a mocha argument matcher, so the assertions
    # read against the real keyword arguments.
    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def import_holding(**kwargs)
        @calls << kwargs
        Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
              .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                   kwargs[:currency], kwargs[:date], kwargs[:external_id])
      end
    end.new

    processor.stubs(:import_adapter).returns(recorder)

    processor.process

    assert_equal 1, recorder.calls.size, "expected the two lots to collapse into a single position"

    position = recorder.calls.first
    assert_in_delta 14.269882, position[:quantity].to_f, 0.000001
    assert_in_delta 3684.19,   position[:amount].to_f,   0.01

    # cost_basis is stored per share, so lots combine as a share-weighted
    # average: (11.891485*200 + 2.378397*250) / 14.269882
    assert_in_delta 208.333, position[:cost_basis].to_f, 0.01

    # price is re-derived from the combined position
    assert_in_delta 258.1781, position[:price].to_f, 0.01
  end

  test "a position with any unknown-basis lot reports no aggregate basis" do
    # Averaging only the lots that reported a basis would apply that figure to
    # shares whose cost is unknown, fabricating cost and gain/loss.
    security = securities(:aapl)
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(nil)

    processor.stubs(:holdings_data).returns([
      { "id" => "lot-known",   "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00", "cost_basis" => "100.00" },
      { "id" => "lot-unknown", "symbol" => "AAPL", "shares" => "10", "market_value" => "2000.00" }
    ])
    processor.stubs(:account).returns(accounts(:investment))
    processor.stubs(:resolve_security).returns(security)
    processor.stubs(:institution_reports_total_basis?).returns(false)
    processor.stubs(:simplefin_account).returns(stub(account_provider: nil))

    recorder = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def import_holding(**kwargs)
        @calls << kwargs
        Struct.new(:id, :security_id, :qty, :amount, :currency, :date, :external_id)
              .new("h", kwargs[:security].id, kwargs[:quantity], kwargs[:amount],
                   kwargs[:currency], kwargs[:date], kwargs[:external_id])
      end
    end.new

    processor.stubs(:import_adapter).returns(recorder)

    processor.process

    assert_equal 1, recorder.calls.size
    position = recorder.calls.first

    # quantity and value still aggregate
    assert_in_delta 20.0,   position[:quantity].to_f, 0.000001
    assert_in_delta 4000.0, position[:amount].to_f,   0.01

    # but the basis is unknown for the position as a whole, NOT $100/share
    assert_nil position[:cost_basis]
  end
end
