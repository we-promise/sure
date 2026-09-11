require "test_helper"

class UI::Account::ValuableOverviewTest < ViewComponent::TestCase
  setup do
    @account = accounts(:investment).family.accounts.create!(name: "Bullion", currency: "USD", balance: 0, accountable: Valuable.new)
    @gold_item = create_bullion_item(material: "gold")
    @silver_item = create_bullion_item(material: "silver")
  end

  test "uses the latest quote for each material in one lookup" do
    ExchangeRate.create!(date: 2.days.ago, from_currency: "XAU", to_currency: "USD", rate: 2_000)
    ExchangeRate.create!(date: Date.yesterday, from_currency: "XAU", to_currency: "USD", rate: 2_100)
    ExchangeRate.create!(date: Date.yesterday, from_currency: "XAG", to_currency: "USD", rate: 30)
    component = UI::Account::ValuableOverview.new(account: @account)

    component.items

    assert_queries_count(1) do
      assert_equal 2_100, component.rate_for(@gold_item).rate
      assert_equal 30, component.rate_for(@silver_item).rate
    end
  end

  test "shows an item's return and explains its pure-metal weight" do
    @gold_item.update!(weight: 10, weight_unit: "gram", purity: 92.6, cost_amount: 500, manual_value: 1_296.73)

    render_inline UI::Account::ValuableOverview.new(account: @account)

    assert_text "10 g gross"
    assert_text "9.26 g pure gold (92.6% purity)"
    assert_text "Gain: +$796.73 (159%)"
  end

  private
    def create_bullion_item(material:)
      @account.valuable.items.create!(
        description: "#{material.capitalize} bar",
        acquired_on: Date.current,
        item_type: "bullion",
        material:,
        weight: 1,
        weight_unit: "troy_ounce",
        purity: 99.9,
        cost_amount: 100
      )
    end
end
