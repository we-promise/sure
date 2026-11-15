require "test_helper"

# Cover transfer exclusions and zero-valued groups without changing currency formatting.
class CurrencyTotalsTest < ActionView::TestCase
  include ApplicationHelper

  test "transfer-only groups preserve their native currency for every transfer kind" do
    Transaction::TRANSFER_KINDS.each do |kind|
      entry = transaction_entry("GBP", 100, kind)
      assert_equal "£0.00", total([ entry ])
      assert_equal "£0.00", total([ entry ], negate: true)
    end
  end

  test "mixed currencies retain group order and exclude transfers" do
    entries = [ transaction_entry("GBP", 100, "funds_movement"),
                transaction_entry("EUR", 20),
                transaction_entry("EUR", 300, "cc_payment"),
                transaction_entry("USD", -5) ]

    assert_equal "£0.00 | €20.00 | -$5.00", total(entries)
    assert_equal "£0.00 / -€20.00 / $5.00", total(entries, negate: true, separator: " / ")
  end

  test "offsetting standard transactions keep their currency" do
    assert_equal "£0.00", total([ transaction_entry("GBP", 20), transaction_entry("GBP", -20) ])
  end

  test "empty collections and zero account balances retain existing behavior" do
    assert_equal "", total([])
    assert_equal "£0.00", totals_by_currency(collection: [ Account.new(currency: "GBP", balance: 0) ], money_method: :balance_money)
  end

  private
    # Build an entry with an explicit currency and transaction kind for total regressions.
    def transaction_entry(currency, amount, kind = "standard")
      Entry.new(currency: currency, amount: amount, entryable: Transaction.new(kind: kind))
    end

    # Exercise the public formatter with the same Money values used by the activity views.
    def total(entries, **options)
      totals_by_currency(collection: entries, money_method: :amount_money, **options)
    end
end
