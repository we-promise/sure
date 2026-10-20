# frozen_string_literal: true

require "test_helper"

class Provider::BankBalanceSnapshotTest < ActiveSupport::TestCase
  FETCHED_AT = Time.utc(2026, 10, 20, 12, 30, 0)

  test "recognizes descriptive balance types and selects each kind by priority" do
    payload = build_snapshot([
      balance("previously_Closed-Booked", amount: "40"),
      balance("openingBooked", amount: "30"),
      balance("interim-booked", amount: "20"),
      balance("closingBooked", amount: "11"),
      balance("CLBD", amount: "10"),
      balance("OPAV", amount: "30"),
      balance("closing-Available", amount: "20"),
      balance("interim_Available", amount: "10"),
      balance("ITAV", amount: "11"),
      balance("expected", amount: "9")
    ])

    snapshot = Provider::BankBalanceSnapshot.new(payload)

    assert_equal BigDecimal("11"), snapshot.booked.money.amount
    assert_equal "closingBooked", snapshot.booked.source_type
    assert_equal BigDecimal("10"), snapshot.available.money.amount
    assert_equal "interim_Available", snapshot.available.source_type
    assert_equal BigDecimal("9"), snapshot.expected.money.amount
    assert_equal "expected", snapshot.expected.source_type
  end

  test "stores JSON-compatible observations with optional dates" do
    payload = build_snapshot([
      balance(
        "CLBD",
        amount: "125.50",
        reference_date: "2026-10-19",
        last_change_date_time: "2026-10-19T14:05:06+02:00"
      )
    ])

    assert_equal FETCHED_AT.iso8601(6), payload.fetch("fetched_at")
    assert_equal FETCHED_AT.iso8601(6), payload.fetch("last_attempted_at")
    assert_equal "complete", payload.fetch("status")
    assert_equal Date.new(2026, 10, 19).iso8601, payload.dig("balances", "booked", "reference_date")
    assert_equal "125.5", payload.dig("balances", "booked", "amount")
    assert_equal "EUR", payload.dig("balances", "booked", "currency")
    assert_kind_of String, JSON.generate(payload)
  end

  test "maps expected to available only for BPER Banca in Italy" do
    payload = build_snapshot(
      [ balance("XPCD", amount: "42", reference_date: "2026-10-19") ],
      bank_name: " BPER Banca ",
      country_code: "it"
    )
    snapshot = Provider::BankBalanceSnapshot.new(payload)

    assert_equal BigDecimal("42"), snapshot.available.money.amount
    assert_equal "XPCD", snapshot.available.source_type
    assert_equal Date.new(2026, 10, 19), snapshot.available.reference_date
    assert snapshot.available.mapped_from_expected?
    assert_nil snapshot.expected
  end

  test "keeps expected separate for other banks and countries" do
    [ [ "BPER Banca", "DE" ], [ "BPER", "IT" ], [ "Example Bank", "IT" ] ].each do |bank_name, country_code|
      snapshot = Provider::BankBalanceSnapshot.new(
        build_snapshot([ balance("expected", amount: "42") ], bank_name:, country_code:)
      )

      assert_nil snapshot.available
      assert_equal BigDecimal("42"), snapshot.expected.money.amount
      assert_not snapshot.expected.mapped_from_expected?
    end
  end

  test "prefers actual availability over expected for BPER" do
    snapshot = Provider::BankBalanceSnapshot.new(
      build_snapshot(
        [ balance("XPCD", amount: "42"), balance("ITAV", amount: "35") ],
        bank_name: "BPER Banca",
        country_code: "IT"
      )
    )

    assert_equal BigDecimal("35"), snapshot.available.money.amount
    assert_equal "ITAV", snapshot.available.source_type
    assert_not snapshot.available.mapped_from_expected?
    assert_equal BigDecimal("42"), snapshot.expected.money.amount
  end

  test "preserves credit signs, applies debit signs, and keeps zero observations" do
    snapshot = Provider::BankBalanceSnapshot.new(
      build_snapshot([
        balance("CLBD", amount: "-12.40", indicator: "CRDT"),
        balance("ITAV", amount: "12.40", indicator: "DBIT"),
        balance("XPCD", amount: "0.00")
      ])
    )

    assert_equal BigDecimal("-12.4"), snapshot.booked.money.amount
    assert_equal BigDecimal("-12.4"), snapshot.available.money.amount
    assert_equal BigDecimal("0"), snapshot.expected.money.amount

    absent_indicator = Provider::BankBalanceSnapshot.new(build_snapshot([ balance("CLBD", amount: "-3") ]))
    assert_equal BigDecimal("-3"), absent_indicator.booked.money.amount
  end

  test "ignores informational, forward-looking, and unknown balance types" do
    balances = %w[FWAV INFO OTHR VALU futureType].map do |type|
      balance(type, amount: "NaN", currency: "ZZZ", indicator: "unknown")
    end
    snapshot = Provider::BankBalanceSnapshot.new(build_snapshot(balances))

    assert_not snapshot.failed?
    assert_nil snapshot.booked
    assert_nil snapshot.available
    assert_nil snapshot.expected
  end

  test "rejects malformed recognized candidates with one sanitized error" do
    invalid_candidates = [
      balance("CLBD", amount: "not-an-amount"),
      balance("CLBD", amount: "Infinity"),
      balance("CLBD", amount: "1", currency: "ZZZ"),
      balance("CLBD", amount: "1", indicator: "unknown")
    ]

    invalid_candidates.each do |candidate|
      error = assert_raises(Provider::BankBalanceSnapshot::InvalidSnapshot) do
        build_snapshot([ candidate ])
      end

      assert_equal Provider::BankBalanceSnapshot::INVALID_SNAPSHOT_MESSAGE, error.message
      refute_includes error.message, "not-an-amount"
    end
  end

  test "rejects missing or malformed balance lists and does not fall back from invalid candidates" do
    assert_invalid_snapshot(nil)
    assert_invalid_snapshot([ nil ])
    assert_invalid_snapshot([
      balance("CLBD", amount: "10"),
      balance("ITBD", amount: "invalid")
    ])

    error = assert_raises(Provider::BankBalanceSnapshot::InvalidSnapshot) do
      Provider::BankBalanceSnapshot.build_enable_banking(
        fetched_at: FETCHED_AT,
        bank_name: "Example Bank",
        country_code: "IT"
      )
    end
    assert_equal Provider::BankBalanceSnapshot::INVALID_SNAPSHOT_MESSAGE, error.message
  end

  test "treats invalid optional dates as absent instead of using fetched_at" do
    snapshot = Provider::BankBalanceSnapshot.new(
      build_snapshot([
        balance("CLBD", amount: "10", reference_date: "2026-02-30", last_change_date_time: "not-a-date")
      ])
    )

    assert_nil snapshot.booked.reference_date
    assert_nil snapshot.booked.last_changed_at

    snapshot = Provider::BankBalanceSnapshot.new(build_snapshot([
      balance("CLBD", amount: "10", last_change_date_time: "2026-10-20T16:30:00")
    ]))
    assert_nil snapshot.booked.last_changed_at
  end

  test "reads valid persisted values and tolerates invalid or partial payloads" do
    assert_nil Provider::BankBalanceSnapshot.new(nil).booked

    partial_payload = build_snapshot([ balance("CLBD", amount: "10") ]).merge(
      "status" => "failed",
      "last_attempted_at" => "invalid-time"
    )
    partial_payload["balances"] = partial_payload.fetch("balances").merge(
      "available" => { "amount" => "NaN", "currency" => "EUR", "source_type" => "ITAV" }
    )

    snapshot = Provider::BankBalanceSnapshot.new(partial_payload)

    assert snapshot.failed?
    assert_equal FETCHED_AT, snapshot.fetched_at
    assert_nil snapshot.last_attempted_at
    assert_equal BigDecimal("10"), snapshot.booked.money.amount
    assert_nil snapshot.available

    invalid_payload = Provider::BankBalanceSnapshot.new(
      "fetched_at" => "invalid-time",
      "balances" => "not-a-hash",
      "status" => "failed"
    )
    assert_nil invalid_payload.fetched_at
    assert_nil invalid_payload.booked
    assert invalid_payload.failed?
  end

  private

    def build_snapshot(balances, bank_name: "Example Bank", country_code: "IT")
      Provider::BankBalanceSnapshot.build_enable_banking(
        balances: balances,
        fetched_at: FETCHED_AT,
        bank_name: bank_name,
        country_code: country_code
      )
    end

    def balance(type, amount:, currency: "EUR", indicator: :absent, **metadata)
      candidate = {
        "balance_type" => type,
        "balance_amount" => { "amount" => amount, "currency" => currency }
      }
      candidate["credit_debit_indicator"] = indicator unless indicator == :absent
      metadata.each { |key, value| candidate[key.to_s] = value }
      candidate
    end

    def assert_invalid_snapshot(balances)
      error = assert_raises(Provider::BankBalanceSnapshot::InvalidSnapshot) do
        build_snapshot(balances)
      end

      assert_equal Provider::BankBalanceSnapshot::INVALID_SNAPSHOT_MESSAGE, error.message
    end
end
