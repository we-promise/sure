require "test_helper"

class Purchase::SummaryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @month = Date.new(2026, 11, 17)
    @ids = []
  end

  test "sums this month's family-currency totals, leaving out rejected orders and other currencies" do
    purchase(ordered_on: Date.new(2026, 11, 3), total: 100, items: 2)
    purchase(ordered_on: Date.new(2026, 11, 10), total: 50, status: :awaiting_payment)
    purchase(ordered_on: Date.new(2026, 11, 11), total: 30, currency: "EUR")
    purchase(ordered_on: Date.new(2026, 11, 12), total: 999, status: :rejected)
    purchase(ordered_on: Date.new(2026, 10, 30), total: 70)

    summary = call

    assert_equal Money.new(150, "USD"), summary.spent
    assert_equal [ Money.new(30, "EUR") ], summary.other_spent
    assert_equal 3, summary.purchases_count
    assert_equal 4, summary.items_count
    assert_equal 1, summary.to_match_count
  end

  test "the most frequent shop this month" do
    purchase(ordered_on: Date.new(2026, 11, 3), total: 10, merchant: "Allegro")
    purchase(ordered_on: Date.new(2026, 11, 4), total: 10, merchant: "Amazon")
    purchase(ordered_on: Date.new(2026, 11, 5), total: 10, merchant: "Allegro")
    purchase(ordered_on: Date.new(2026, 10, 5), total: 10, merchant: "Amazon")
    purchase(ordered_on: Date.new(2026, 10, 6), total: 10, merchant: "Amazon")

    summary = call

    assert_equal "Allegro", summary.top_merchant
    assert_equal 2, summary.top_merchant_count
  end

  test "an empty month spends nothing and has no top shop" do
    summary = call

    assert_equal Money.new(0, "USD"), summary.spent
    assert_equal 0, summary.purchases_count
    assert_nil summary.top_merchant
  end

  test "month totals group the whole scope by month, family currency first" do
    purchase(ordered_on: Date.new(2026, 11, 3), total: 100)
    purchase(ordered_on: Date.new(2026, 11, 11), total: 30, currency: "EUR")
    purchase(ordered_on: Date.new(2026, 11, 12), total: 999, status: :failed)
    purchase(ordered_on: Date.new(2026, 10, 30), total: 70)
    purchase(ordered_on: nil, total: 5)

    totals = Purchase::Summary.month_totals(scope, currency: "USD")

    assert_equal [ Money.new(100, "USD"), Money.new(30, "EUR") ], totals[Date.new(2026, 11, 1)]
    assert_equal [ Money.new(70, "USD") ], totals[Date.new(2026, 10, 1)]
    assert_equal [ Money.new(5, "USD") ], totals[nil]
  end

  test "orders without a currency or with a lowercase code count in the family's sum" do
    purchase(ordered_on: Date.new(2026, 11, 3), total: 100)
    purchase(ordered_on: Date.new(2026, 11, 4), total: 5, currency: nil)
    purchase(ordered_on: Date.new(2026, 11, 5), total: 1, currency: "usd")

    assert_equal Money.new(106, "USD"), call.spent
    assert_empty call.other_spent
    assert_equal [ Money.new(106, "USD") ], Purchase::Summary.month_totals(scope, currency: "USD")[Date.new(2026, 11, 1)]
  end

  test "an order in a currency nobody knows is left out of the totals instead of breaking them" do
    purchase(ordered_on: Date.new(2026, 11, 3), total: 100)
    purchase(ordered_on: Date.new(2026, 11, 4), total: 5, currency: "ZL")

    assert_equal Money.new(100, "USD"), call.spent
    assert_empty call.other_spent
    assert_equal [ Money.new(100, "USD") ], Purchase::Summary.month_totals(scope, currency: "USD")[Date.new(2026, 11, 1)]
  end

  private
    def call
      Purchase::Summary.new(scope, currency: "USD", month: @month).call
    end

    def scope
      Purchase.where(id: @ids)
    end

    def purchase(ordered_on:, total:, currency: "USD", status: :matched, merchant: "Allegro", items: 1)
      record = Purchase.create!(family: @family, user: @user, source: :email, status:, merchant:, ordered_on:, total:, currency:)
      items.times { |position| record.items.create!(name: "Item #{position}", amount: 1, position:) }
      @ids << record.id
      record
    end
end
