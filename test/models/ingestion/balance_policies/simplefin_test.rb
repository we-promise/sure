require "test_helper"
require "ostruct"

class Ingestion::BalancePolicies::SimplefinTest < ActiveSupport::TestCase
  Policy = Ingestion::BalancePolicies::Simplefin

  setup do
    @now = Time.utc(2026, 1, 31)
    @settings = {
      "window_days" => 120, "min_txns" => 10, "min_payments" => 2,
      "epsilon_base" => BigDecimal("0.50"), "statement_guard_days" => 5, "sticky_days" => 7
    }
  end

  test "captured aggregate evaluation matches legacy credit debt guard and mismatch decisions" do
    credit = transactions(charges: Array.new(9, 10), payments: Array.new(3, 40))
    debt = transactions(charges: Array.new(8, 20), payments: Array.new(2, 50))
    guarded = transactions(charges: Array.new(8, 20), payments: Array.new(2, 50), recent: true)
    [ [ credit, -30 ], [ debt, -60 ], [ debt, -50 ], [ guarded, -60 ] ].each do |rows, observed|
      expected = legacy(rows, observed: observed).call
      actual = Policy.new(snapshot: snapshot(entry_metrics: metrics(rows))).call(observed_balance: BigDecimal(observed.to_s))

      assert_equal expected.classification, actual.classification
      assert_equal expected.reason, actual.reason
      assert_equal expected.metrics, actual.metrics
    end
  end

  test "insufficient entry history uses captured raw fallback while sufficient entries take precedence" do
    entries = transactions(charges: [ 1 ], payments: [])
    raw = transactions(charges: Array.new(9, 10), payments: Array.new(3, 40))
    result = Policy.new(snapshot: snapshot(entry_metrics: metrics(entries), raw_metrics: metrics(raw))).call(observed_balance: BigDecimal("-30"))
    assert_equal :credit, result.classification
    assert_equal 12, result.metrics.fetch(:tx_count)

    enough = transactions(charges: Array.new(8, 20), payments: Array.new(2, 50))
    result = Policy.new(snapshot: snapshot(entry_metrics: metrics(enough), raw_metrics: metrics(raw))).call(observed_balance: BigDecimal("-60"))
    assert_equal :debt, result.classification
    assert_equal 10, result.metrics.fetch(:tx_count)
  end

  test "fresh and expired sticky hints match legacy precedence without reading the live cache" do
    hint = { "value" => "credit", "expires_at" => (@now + 1.day).iso8601 }
    result = Policy.new(snapshot: snapshot(sticky_hint: hint)).call(observed_balance: BigDecimal("123"))
    assert_equal :credit, result.classification
    assert_equal "sticky_hint", result.reason
    assert_empty result.metrics

    expired = hint.merge("expires_at" => @now.iso8601)
    result = Policy.new(snapshot: snapshot(sticky_hint: expired)).call(observed_balance: BigDecimal("123"))
    assert_equal :unknown, result.classification
    assert_equal "insufficient-txns", result.reason
  end

  test "disabled no-account non-liability near-zero and insufficient histories remain unknown" do
    cases = [ [ { enabled: false }, "flag disabled", "10" ], [ { account_type: nil }, "no-account", "10" ],
      [ { account_type: "Depository" }, "not-liability", "10" ], [ {}, "near-zero-balance", "0.50" ],
      [ {}, "insufficient-txns", "10" ] ]
    cases.each do |overrides, reason, amount|
      result = Policy.new(snapshot: snapshot(**overrides)).call(observed_balance: BigDecimal(amount))
      assert_equal :unknown, result.classification
      assert_equal reason, result.reason
    end
  end

  test "policy snapshot and result are durable encrypted batch evidence with exact decimals" do
    input = snapshot(entry_metrics: metrics(transactions(charges: Array.new(8, 20), payments: Array.new(2, 50))))
    result = Policy.new(snapshot: input).call(observed_balance: BigDecimal("-60"))
    evidence = { "balance_policy" => input, "result" => {
      "classification" => result.classification.to_s, "reason" => result.reason, "metrics" => result.metrics
    } }
    page = Provider::AccountData::Page.new(records: [], complete: true, evidence: evidence)
    restored = Ingestion::Codec.load(Ingestion::Codec.dump(page))
    copied_input = restored.evidence.fetch("balance_policy")
    replay = Policy.new(snapshot: copied_input).call(observed_balance: BigDecimal("-60"))

    assert_equal result, replay
    assert_instance_of BigDecimal, replay.metrics.fetch(:charges_total)
  end

  test "invalid or inconsistent snapshots fail without coercing financial values" do
    invalid = [ snapshot(schema_version: 2), snapshot(enabled: "true"),
      snapshot(settings: @settings.merge("epsilon_base" => Float::NAN)),
      snapshot(settings: @settings.merge("min_txns" => 0)),
      snapshot(settings: @settings.merge("sticky_days" => 0)),
      snapshot(entry_metrics: { "tx_count" => 1 }),
      snapshot(entry_metrics: metrics([]).merge("payments_count" => 2)),
      snapshot(entry_metrics: metrics([]).merge("charges_total" => "NaN")) ]
    invalid.each do |input|
      assert_raises(Policy::InvalidSnapshot) { Policy.new(snapshot: input).call(observed_balance: BigDecimal("10")) }
    end
    assert_raises(Policy::InvalidSnapshot) { Policy.new(snapshot: snapshot).call(observed_balance: 10.25) }
  end

  private
    def snapshot(**attributes)
      { "schema_version" => 1, "enabled" => true, "account_type" => "CreditCard", "as_of" => @now.iso8601,
        "settings" => @settings, "sticky_hint" => nil, "entry_metrics" => nil, "raw_metrics" => nil }.merge(attributes.stringify_keys)
    end

    def transactions(charges:, payments:, recent: false)
      date = @now.to_date - (recent ? 1 : 10)
      charges.map { |amount| { amount: BigDecimal(amount.to_s), date: date } } +
        payments.map { |amount| { amount: -BigDecimal(amount.to_s), date: date } }
    end

    def metrics(rows)
      {
        "tx_count" => rows.size,
        "charges_total" => rows.sum(BigDecimal("0")) { |row| row[:amount].positive? ? row[:amount] : BigDecimal("0") },
        "payments_total" => rows.sum(BigDecimal("0")) { |row| row[:amount].negative? ? -row[:amount] : BigDecimal("0") },
        "payments_count" => rows.count { |row| row[:amount].negative? },
        "recent_payment" => rows.any? { |row| row[:amount].negative? && row[:date] >= @now.to_date - @settings.fetch("statement_guard_days") }
      }
    end

    def legacy(rows, observed:)
      source = OpenStruct.new(current_account: OpenStruct.new(accountable_type: "CreditCard"))
      SimplefinAccount::Liabilities::OverpaymentAnalyzer.new(source, observed_balance: observed, now: @now).tap do |analyzer|
        analyzer.stubs(:enabled?).returns(true)
        analyzer.stubs(:read_sticky).returns(nil)
        analyzer.stubs(:write_sticky)
        analyzer.stubs(:gather_transactions).returns(rows)
        @settings.each { |key, value| analyzer.stubs(key.to_sym).returns(value) }
      end
    end
end
