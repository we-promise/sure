require "test_helper"

class IndianGoldInvestmentTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = @family.users.first
  end

  test "classification returns asset" do
    assert_equal "asset", IndianGoldInvestment.classification
  end

  test "icon returns gem" do
    assert_equal "gem", IndianGoldInvestment.icon
  end

  test "color returns correct hex" do
    assert_equal "#D97706", IndianGoldInvestment.color
  end

  test "SUBTYPES contains gold investment types" do
    expected_subtypes = %w[physical_gold gold_etf sgb gold_mutual_fund digital_gold]
    expected_subtypes.each do |subtype|
      assert IndianGoldInvestment::SUBTYPES.key?(subtype), "Missing subtype: #{subtype}"
    end
  end

  test "SGB is tax exempt" do
    sgb = IndianGoldInvestment.new(subtype: "sgb")
    assert_equal :tax_exempt, sgb.tax_treatment
  end

  test "physical_gold is taxable" do
    gold = IndianGoldInvestment.new(subtype: "physical_gold")
    assert_equal :taxable, gold.tax_treatment
  end

  test "subtypes_grouped_for_select returns grouped options" do
    grouped = IndianGoldInvestment.subtypes_grouped_for_select
    assert grouped.is_a?(Array)
    assert_equal 1, grouped.size
  end

  test "can create account with accountable" do
    account = @family.accounts.create!(
      accountable: IndianGoldInvestment.new(subtype: "physical_gold", quantity_grams: "50", purity: "24k", purchase_price_per_gram: "5000"),
      name: "My Gold Investment",
      balance: 250000,
      currency: "INR"
    )

    assert account.persisted?
    assert_equal "physical_gold", account.subtype
    assert_in_delta 50, account.accountable.quantity_grams.to_d, 0.001
    assert_equal "24k", account.accountable.purity
  end

  test "total_purchase_value calculates correctly" do
    gold = IndianGoldInvestment.new(quantity_grams: "10", purchase_price_per_gram: "5000")
    assert_equal 50000, gold.total_purchase_value
  end

  test "quantity_display formats correctly" do
    gold = IndianGoldInvestment.new(quantity_grams: "10.5", weight_unit: "grams")
    assert_equal "10.5 grams", gold.quantity_display
  end
end
