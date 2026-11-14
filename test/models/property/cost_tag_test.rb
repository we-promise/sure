require "test_helper"

class Property::CostTagTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @admin = users(:family_admin)
    @account = accounts(:property)
    @property = @account.property
    @family = @account.family
    @tag = @family.tags.create!(name: "Land costs")
    @property.update!(cost_tag: @tag)

    @purchase_date = 2.years.ago.to_date
    @account.entries.valuations.destroy_all
    @account.entries.create!(
      date: @purchase_date, name: "Original purchase price", amount: 500_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @account.update!(balance: 550_000)
  end

  test "sums the tagged transactions in any of the family's accounts into the cost basis" do
    create_transaction(account: accounts(:depository), amount: 8_000, date: @purchase_date, tags: [ @tag ])
    create_transaction(account: accounts(:credit_card), amount: 2_500, date: @purchase_date + 3, tags: [ @tag ])
    # A refund reduces the costs.
    create_transaction(account: accounts(:depository), amount: -500, date: @purchase_date + 30, tags: [ @tag ])
    # Untagged and excluded transactions do not count.
    create_transaction(account: accounts(:depository), amount: 1_000, date: @purchase_date)
    create_transaction(account: accounts(:depository), amount: 9_999, date: @purchase_date, tags: [ @tag ], excluded: true)

    assert_equal Money.new(10_000, "USD"), @property.purchase_costs_for(@admin)
    assert_equal Money.new(510_000, "USD"), @property.cost_basis_for(@admin)

    trend = @property.cost_adjusted_trend_for(@admin)
    assert_equal Money.new(40_000, "USD"), trend.value
    assert_equal 7.8, trend.percent
    # The existing trend against the purchase price is unchanged.
    assert_equal Money.new(50_000, "USD"), @property.trend.value
  end

  test "has no costs without a cost tag" do
    create_transaction(account: accounts(:depository), amount: 8_000, tags: [ @tag ])
    @property.update!(cost_tag: nil)

    assert_equal Money.new(0, "USD"), @property.purchase_costs_for(@admin)
    assert_equal Money.new(500_000, "USD"), @property.cost_basis_for(@admin)
  end

  test "converts a cost in another currency at the stored rate on its own date" do
    eur_account = @family.accounts.create!(name: "Euro bank", balance: 0, currency: "EUR", owner: @admin, accountable: Depository.new)
    create_transaction(account: eur_account, amount: 1_000, currency: "EUR", date: @purchase_date, tags: [ @tag ])
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @purchase_date, rate: 1.2)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)

    assert_equal Money.new(1_200, "USD"), @property.purchase_costs_for(@admin)
    assert_equal Money.new(501_200, "USD"), @property.cost_basis_for(@admin)
  end

  test "costs are unavailable without a stored rate and never fetch one" do
    eur_account = @family.accounts.create!(name: "Euro bank", balance: 0, currency: "EUR", owner: @admin, accountable: Depository.new)
    create_transaction(account: eur_account, amount: 1_000, currency: "EUR", date: @purchase_date, tags: [ @tag ])
    create_transaction(account: accounts(:depository), amount: 8_000, date: @purchase_date, tags: [ @tag ])
    ExchangeRate.expects(:provider).never

    assert_nil @property.purchase_costs_for(@admin)
    assert_nil @property.cost_basis_for(@admin)
    assert_nil @property.cost_adjusted_trend_for(@admin)
  end

  test "only counts the costs in accounts the viewer can see" do
    member = users(:family_member)
    # Shared with the member.
    create_transaction(account: accounts(:depository), amount: 8_000, date: @purchase_date, tags: [ @tag ])
    # Not shared with the member.
    create_transaction(account: accounts(:investment), amount: 3_000, date: @purchase_date, tags: [ @tag ])

    assert_equal Money.new(11_000, "USD"), @property.purchase_costs_for(@admin)
    assert_equal Money.new(8_000, "USD"), @property.purchase_costs_for(member)
    assert_equal 1, @property.cost_entries_for(member).count
  end

  test "measures the gain after costs in the family currency for a foreign-currency property" do
    @family.update!(currency: "EUR")
    eur_account = @family.accounts.create!(name: "Euro bank", balance: 0, currency: "EUR", owner: @admin, accountable: Depository.new)
    create_transaction(account: eur_account, amount: 10_000, currency: "EUR", date: @purchase_date, tags: [ @tag ])
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: @purchase_date, rate: 1.0)
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)

    trend = @property.family_currency_cost_adjusted_trend_for(@admin)

    # 550,000 USD at 0.9 is 495,000 EUR, against 500,000 + 10,000 EUR.
    assert_equal Money.new(510_000, "EUR"), trend.previous
    assert_equal Money.new(495_000, "EUR"), trend.current
    # The EUR cost has no stored rate to USD, so the property-currency figure is unavailable.
    assert_nil @property.cost_adjusted_trend_for(@admin)
  end

  test "the cost tag must belong to the property's family" do
    other_tag = families(:empty).tags.create!(name: "Someone else's")

    assert_not @account.update(accountable_attributes: { id: @property.id, cost_tag_id: other_tag.id })
    assert_equal @tag.id, @property.reload.cost_tag_id
  end

  test "deleting the tag unlinks the property and replacing it moves the link" do
    replacement = @family.tags.create!(name: "Plot costs")

    @tag.replace_and_destroy!(replacement)
    assert_equal replacement.id, @property.reload.cost_tag_id

    replacement.destroy!
    assert_nil @property.reload.cost_tag_id
  end
end
