require "test_helper"

class PhysicalGoldLotTest < ActiveSupport::TestCase
  test "values each physical-gold purchase by its fine-gold content" do
    account = accounts(:investment)
    account.holdings.destroy_all
    account.investment.update!(subtype: "gold", gold_form: "physical")

    lot = account.physical_gold_lots.create!(description: "Bracelet", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 18, cost_amount: 8_000)

    assert_in_delta 75, lot.fine_weight_in_grams, 0.001
    assert_in_delta 7_500, lot.value_for(3_110.34768), 0.01
  end

  test "refuses lots on digital gold accounts" do
    account = accounts(:investment)
    account.investment.update!(subtype: "gold", gold_form: "digital")

    lot = account.physical_gold_lots.build(acquired_on: Date.current, weight: 1, weight_unit: "gram", karat: 24)

    assert_not lot.valid?
    assert_includes lot.errors[:account], "must be a physical gold investment"
  end

  test "requires a description and purchase price" do
    account = accounts(:investment)
    account.holdings.destroy_all
    account.investment.update!(subtype: "gold", gold_form: "physical")
    lot = account.physical_gold_lots.build(acquired_on: Date.current, weight: 1, weight_unit: "gram", karat: 24)

    assert_not lot.valid?
    assert_includes lot.errors[:description], "can't be blank"
    assert_includes lot.errors[:cost_amount], "is not a number"
  end

  test "uses its individual manual value when present" do
    account = accounts(:investment)
    account.holdings.destroy_all
    account.investment.update!(subtype: "gold", gold_form: "physical")
    lot = account.physical_gold_lots.create!(description: "Bracelet", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 18, cost_amount: 8_000, manual_value: 9_000)

    assert lot.manual_value?
    assert_equal 9_000, lot.value_for(3_110.34768)
  end

  test "adds optional making charges to the total paid" do
    account = accounts(:investment)
    account.holdings.destroy_all
    account.investment.update!(subtype: "gold", gold_form: "physical")
    lot = account.physical_gold_lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000, making_charge: 50)

    assert_equal 1_050, lot.total_cost_amount
  end
end
