require "test_helper"

class ValuableItemTest < ActiveSupport::TestCase
  test "values each physical-gold purchase by its fine-gold content" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)

    lot = account.valuable.lots.create!(description: "Bracelet", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 18, cost_amount: 8_000)

    assert_in_delta 75, lot.fine_weight_in_grams, 0.001
    assert_in_delta 7_500, lot.value_for(3_110.34768), 0.01
  end

  test "requires a precious metal owner" do
    lot = ValuableItem.new(description: "Coin", acquired_on: Date.current, weight: 1, weight_unit: "gram", karat: 24, cost_amount: 1, currency: "USD")
    assert_not lot.valid?
    assert_includes lot.errors[:valuable], "must exist"
  end

  test "requires a description and purchase price" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    lot = account.valuable.lots.build(acquired_on: Date.current, weight: 1, weight_unit: "gram", karat: 24)

    assert_not lot.valid?
    assert_includes lot.errors[:description], "can't be blank"
    assert_includes lot.errors[:cost_amount], "is not a number"
  end

  test "rejects a blank description" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    lot = account.valuable.lots.build(description: "  ", acquired_on: Date.current, weight: 1, weight_unit: "gram", karat: 24, cost_amount: 1)

    assert_not lot.valid?
    assert_includes lot.errors[:description], "can't be blank"
  end

  test "uses its individual manual value when present" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    lot = account.valuable.lots.create!(description: "Bracelet", acquired_on: Date.current, weight: 100, weight_unit: "gram", karat: 18, cost_amount: 8_000, manual_value: 9_000)

    assert lot.manual_value?
    assert_equal 9_000, lot.value_for(3_110.34768)
  end

  test "adds optional making charges to the total paid" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    lot = account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000, making_charge: 50)

    assert_equal 1_050, lot.total_cost_amount
  end

  test "accepts a PDF invoice" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    lot = account.valuable.lots.build(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
    lot.invoice.attach(io: StringIO.new("invoice"), filename: "invoice.pdf", content_type: "application/pdf")

    assert lot.valid?
  end

  test "rejects an unsupported invoice format" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    lot = account.valuable.lots.build(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
    lot.invoice.attach(io: StringIO.new("invoice"), filename: "invoice.txt", content_type: "text/plain")

    assert_not lot.valid?
    assert_includes lot.errors.full_messages_for(:invoice).join, "must be a PDF or image"
  end

  test "nullifies the merchant when it is deleted" do
    account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    merchant = merchants(:one)
    lot = account.valuable.lots.create!(description: "Coin", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000, merchant: merchant)

    merchant.destroy!

    assert_nil lot.reload.merchant
  end

  test "supports silver bullion with percentage purity and its own quote symbol" do
    account = accounts(:investment).family.accounts.create!(name: "Bullion", currency: "USD", balance: 0, accountable: Valuable.new)
    item = account.valuable.items.create!(description: "Silver bar", acquired_on: Date.current, item_type: "bullion", material: "silver", weight: 1, weight_unit: "troy_ounce", purity: 99.9, cost_amount: 40)

    assert_equal "XAG", item.quote_symbol
    assert_in_delta 31.072, item.fine_weight_in_grams, 0.001
  end

  test "requires gemstones to use carats and an appraised value" do
    account = accounts(:investment).family.accounts.create!(name: "Gems", currency: "USD", balance: 0, accountable: Valuable.new)
    item = account.valuable.items.build(description: "Sapphire", acquired_on: Date.current, item_type: "gemstone", material: "sapphire", weight: 2, weight_unit: "carat", cost_amount: 500)

    assert_not item.valid?
    assert_includes item.errors[:manual_value], "can't be blank"
    item.manual_value = 750
    assert item.save
    assert_equal 750, item.value_for
  end

  test "database prevents conflicting item-type fields" do
    account = accounts(:investment).family.accounts.create!(name: "Collection", currency: "USD", balance: 0, accountable: Valuable.new)

    gemstone = account.valuable.items.build(
      description: "Ruby", acquired_on: Date.current, item_type: "gemstone", material: "ruby",
      weight: 1, weight_unit: "carat", purity: 99, cost_amount: 100, manual_value: 200, currency: "USD"
    )
    bullion = account.valuable.items.build(
      description: "Gold coin", acquired_on: Date.current, item_type: "bullion", material: "gold",
      weight: 1, weight_unit: "carat", purity: 99, cost_amount: 100, currency: "USD"
    )
    invalid_material = account.valuable.items.build(
      description: "Diamond bullion", acquired_on: Date.current, item_type: "bullion", material: "diamond",
      weight: 1, weight_unit: "gram", purity: 99, cost_amount: 100, currency: "USD"
    )

    assert_raises(ActiveRecord::StatementInvalid) { gemstone.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { bullion.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { invalid_material.save!(validate: false) }
  end
end
