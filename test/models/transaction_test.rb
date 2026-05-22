require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  test "pending? is true when extra.simplefin.pending is truthy" do
    transaction = Transaction.new(extra: { "simplefin" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? is true when extra.plaid.pending is truthy" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => "true" } })

    assert transaction.pending?
  end

  test "pending? is true when extra.lunchflow.pending is truthy" do
    transaction = Transaction.new(extra: { "lunchflow" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? is false when no provider pending metadata is present" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => false } })

    assert_not transaction.pending?
  end

  test "pending? returns true for enable_banking pending transactions" do
    transaction = Transaction.new(extra: { "enable_banking" => { "pending" => true } })

    assert transaction.pending?
  end

  test "pending? returns false for enable_banking non-pending transactions" do
    transaction = Transaction.new(extra: { "enable_banking" => { "pending" => false } })

    assert_not transaction.pending?
  end

  test "investment_contribution is a valid kind" do
    transaction = Transaction.new(kind: "investment_contribution")

    assert_equal "investment_contribution", transaction.kind
    assert transaction.investment_contribution?
  end

  test "TRANSFER_KINDS constant matches transfer? method" do
    Transaction::TRANSFER_KINDS.each do |kind|
      assert Transaction.new(kind: kind).transfer?, "#{kind} should be a transfer kind"
    end

    non_transfer_kinds = Transaction.kinds.keys - Transaction::TRANSFER_KINDS
    non_transfer_kinds.each do |kind|
      assert_not Transaction.new(kind: kind).transfer?, "#{kind} should NOT be a transfer kind"
    end
  end

  test "all transaction kinds are valid" do
    valid_kinds = %w[standard funds_movement cc_payment loan_payment one_time investment_contribution]

    valid_kinds.each do |kind|
      transaction = Transaction.new(kind: kind)
      assert_equal kind, transaction.kind, "#{kind} should be a valid transaction kind"
    end
  end

  test "ACTIVITY_LABELS contains all valid labels" do
    assert_includes Transaction::ACTIVITY_LABELS, "Buy"
    assert_includes Transaction::ACTIVITY_LABELS, "Sell"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep In"
    assert_includes Transaction::ACTIVITY_LABELS, "Sweep Out"
    assert_includes Transaction::ACTIVITY_LABELS, "Dividend"
    assert_includes Transaction::ACTIVITY_LABELS, "Reinvestment"
    assert_includes Transaction::ACTIVITY_LABELS, "Interest"
    assert_includes Transaction::ACTIVITY_LABELS, "Fee"
    assert_includes Transaction::ACTIVITY_LABELS, "Transfer"
    assert_includes Transaction::ACTIVITY_LABELS, "Contribution"
    assert_includes Transaction::ACTIVITY_LABELS, "Withdrawal"
    assert_includes Transaction::ACTIVITY_LABELS, "Exchange"
    assert_includes Transaction::ACTIVITY_LABELS, "Other"
  end

  test "exchange_rate getter returns nil when extra is nil" do
    transaction = Transaction.new
    assert_nil transaction.exchange_rate
  end

  test "exchange_rate setter stores normalized numeric value" do
    transaction = Transaction.new
    transaction.exchange_rate = "1.5"

    assert_equal 1.5, transaction.exchange_rate
  end

  test "exchange_rate setter marks invalid input" do
    transaction = Transaction.new
    transaction.exchange_rate = "not a number"

    assert_equal "not a number", transaction.extra["exchange_rate"]
    assert transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate setter rejects non-finite input" do
    transaction = Transaction.new
    transaction.exchange_rate = "Infinity"

    assert_equal "Infinity", transaction.extra["exchange_rate"]
    assert transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate setter clears invalid flag for valid input" do
    transaction = Transaction.new
    transaction.exchange_rate = "not a number"
    transaction.exchange_rate = "1.5"

    assert_equal 1.5, transaction.exchange_rate
    assert_equal false, transaction.extra["exchange_rate_invalid"]
  end

  test "exchange_rate validation rejects non-numeric input" do
    transaction = Transaction.new(
      category: categories(:income),
      extra: { "exchange_rate" => "invalid" }
    )
    transaction.exchange_rate = "not a number"

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be a number"
  end

  test "exchange_rate validation rejects zero values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = 0

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be greater than 0"
  end

  test "exchange_rate validation rejects negative values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = -1.5

    assert_not transaction.valid?
    assert_includes transaction.errors[:exchange_rate], "must be greater than 0"
  end

  test "exchange_rate validation allows positive values" do
    transaction = Transaction.new(
      category: categories(:income)
    )
    transaction.exchange_rate = 1.5

    assert transaction.valid?
  end

  test "activity_security returns the referenced security from extra metadata" do
    security = securities(:aapl)
    transaction = Transaction.new(extra: { "security_id" => security.id })

    assert_equal security, transaction.activity_security
  end

  test "activity_security returns nil when no security metadata is present" do
    transaction = Transaction.new(extra: {})

    assert_nil transaction.activity_security
  end

  test "activity_security refreshes when security metadata changes on the same instance" do
    transaction = Transaction.new(extra: { "security_id" => securities(:aapl).id })

    assert_equal securities(:aapl), transaction.activity_security

    transaction.extra["security_id"] = securities(:msft).id

    assert_equal securities(:msft), transaction.activity_security
  end
end
