require "test_helper"

class ScalableItem::HistoryNormalizerTest < ActiveSupport::TestCase
  test "normalizes signed settled EUR deposits and withdrawals with stable source dates" do
    result = normalize(
      [
        row("cash-deposit", amount: "50.00", event_date: "2026-10-19T00:00:00Z", description: "Deposit", status: "CONFIRMED"),
        row("cash-withdrawal", transaction_type: "WITHDRAWAL", amount: "-1.00", event_date: "2025-12-08T23:30:00Z")
      ]
    )

    deposit, withdrawal = result.activities
    assert_equal Date.new(2026, 10, 19), deposit.date
    assert_equal BigDecimal("-50.00"), deposit.amount
    assert_equal "EUR", deposit.currency
    assert_equal "Deposit", deposit.name
    assert_equal({
      "cash_transaction_type" => "DEPOSIT",
      "source_id" => "cash-deposit",
      "status" => "CONFIRMED"
    }, deposit.metadata)

    assert_equal Date.new(2025, 12, 8), withdrawal.date
    assert_equal BigDecimal("1.00"), withdrawal.amount
    assert_equal "Scalable withdrawal", withdrawal.name
    assert_equal({
      "cash_transaction_type" => "WITHDRAWAL",
      "source_id" => "cash-withdrawal",
      "status" => "CONFIRMED"
    }, withdrawal.metadata)

    expected_id = "scalable-history-v1:#{Digest::SHA256.hexdigest(JSON.generate([ "portfolio-1", "cash-deposit" ]))}"
    assert_equal expected_id, deposit.external_id
    assert_equal expected_id, normalize([ row("cash-deposit", amount: "50.00") ]).activities.sole.external_id
    assert_equal 64, deposit.external_id.delete_prefix("scalable-history-v1:").length
  end

  test "skips explicit pending and cancelled rows without importing their amounts" do
    pending = row("cash-pending").merge("isPending" => true, "cashTransactionHistory" => [])
    cancelled = row("cash-cancelled").merge("isCancellation" => true, "cashTransactionHistory" => [])
    pending_history = row("cash-pending-history", history: [ "PENDING" ])
    cancelled_history = row("cash-cancelled-history", history: [ "CANCELLED" ])

    assert_empty normalize([ pending, cancelled, pending_history, cancelled_history ]).activities
  end

  test "rejects unknown settlement combinations and duplicate source identities" do
    error = assert_raises(Provider::Scalable::Error) do
      normalize([ row("cash-unknown", history: [ "BOOKED" ]) ])
    end
    assert_equal "history_incomplete", error.code

    duplicate = row("cash-duplicate").merge("isPending" => true)
    error = assert_raises(Provider::Scalable::Error) do
      normalize([ duplicate, duplicate ])
    end
    assert_equal "history_incomplete", error.code
  end

  test "requires a verified settled summary status before importing cash" do
    [ nil, "BOOKED", "PENDING" ].each do |status|
      error = assert_raises(Provider::Scalable::Error) do
        normalize([ row("cash-status-#{status}", status: status) ])
      end
      assert_equal "history_incomplete", error.code
    end
  end

  test "rejects unsupported transaction types, currencies, and signs" do
    unsupported_type = row("cash-fee").merge("cashTransactionType" => "FEE")
    unsupported_currency = row("cash-usd").merge("currency" => "USD")
    wrong_deposit_sign = row("cash-wrong-deposit", amount: "-5.00")
    wrong_withdrawal_sign = row("cash-wrong-withdrawal", transaction_type: "WITHDRAWAL", amount: "5.00")
    noncash = row("trade-1").merge("__typename" => "BrokerSecurityTransaction", "type" => "TRADE")

    [ unsupported_type, unsupported_currency, noncash ].each do |unsupported|
      error = assert_raises(Provider::Scalable::Error) { normalize([ unsupported ]) }
      assert_equal "history_unsupported", error.code
    end

    [ wrong_deposit_sign, wrong_withdrawal_sign ].each do |invalid|
      error = assert_raises(Provider::Scalable::Error) { normalize([ invalid ]) }
      assert_equal "history_incomplete", error.code
    end
  end

  test "rejects amounts outside EUR database scale and precision" do
    [ "0.00001", "1000000000000000", "NaN", "invalid" ].each do |amount|
      error = assert_raises(Provider::Scalable::Error) do
        normalize([ row("cash-invalid-#{amount}", amount: amount) ])
      end
      assert_equal "history_incomplete", error.code
    end
  end

  test "keeps provider descriptions and metadata bounded" do
    oversized = row("cash-long-name", description: "x" * (ScalableItem::HistoryNormalizer::MAX_DESCRIPTION_BYTES + 1))
    error = assert_raises(Provider::Scalable::Error) { normalize([ oversized ]) }
    assert_equal "history_incomplete", error.code

    activity = normalize([ row("cash-safe") ]).activities.sole
    assert_equal %w[cash_transaction_type source_id status], activity.metadata.keys.sort
    refute activity.metadata.key?("description")
    refute activity.metadata.key?("cashTransactionHistory")
  end

  private

    def normalize(rows)
      ScalableItem::HistoryNormalizer.new(rows: rows, portfolio_id: "portfolio-1").normalize
    end

    def row(id, transaction_type: "DEPOSIT", amount: "50.00", event_date: "2026-10-19T00:00:00Z",
      description: nil, status: "CONFIRMED", history: [ "PENDING", "SETTLED" ])
      {
        "__typename" => "BrokerCashTransaction",
        "id" => id,
        "currency" => "EUR",
        "type" => "CASH_TRANSACTION",
        "lastEventDateTime" => event_date,
        "isPending" => false,
        "isCancellation" => false,
        "cashTransactionType" => transaction_type,
        "amount" => amount,
        "description" => description,
        "summary_status" => status,
        "cashTransactionHistory" => history.map { |state| { "state" => state } }
      }
    end
end
