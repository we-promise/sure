require "test_helper"

class Transaction::ActivitySecurityPreloaderTest < ActiveSupport::TestCase
  test "preloads activity securities for transactions" do
    transaction = Transaction.new(extra: { "security_id" => securities(:aapl).id })

    Transaction::ActivitySecurityPreloader.new([ transaction ]).preload

    assert_equal securities(:aapl), transaction.activity_security
  end

  test "preloads activity securities for entry collections" do
    transaction = Transaction.new(extra: { "security_id" => securities(:aapl).id })
    entry = Entry.new(account: accounts(:depository), entryable: transaction, date: Date.current, name: "Dividend", amount: 10, currency: "USD")

    Transaction::ActivitySecurityPreloader.new([ entry ]).preload

    assert_equal securities(:aapl), transaction.activity_security
  end

  test "sets nil when the referenced security cannot be found" do
    transaction = Transaction.new(extra: { "security_id" => SecureRandom.uuid })

    Transaction::ActivitySecurityPreloader.new([ transaction ]).preload

    assert_nil transaction.activity_security
  end
end
