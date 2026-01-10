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

  test "pending? is false when no provider pending metadata is present" do
    transaction = Transaction.new(extra: { "plaid" => { "pending" => false } })

    assert_not transaction.pending?
  end
end
