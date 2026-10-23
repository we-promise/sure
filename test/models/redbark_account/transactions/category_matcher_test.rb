require "test_helper"

class RedbarkAccount::Transactions::CategoryMatcherTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @family.categories.bootstrap! # creates Sure's default categories
    @matcher = RedbarkAccount::Transactions::CategoryMatcher.new(@family.categories.to_a)
  end

  test "maps high-confidence Redbark categories to default Sure categories" do
    expectations = {
      "BANK_FEES"        => "Fees",
      "ENTERTAINMENT"    => "Entertainment",
      "FOOD_AND_DRINK"   => "Food & Drink",
      "HOME_IMPROVEMENT" => "Home Improvement",
      "INCOME"           => "Income",
      "LOAN_PAYMENTS"    => "Loan Payments",
      "MEDICAL"          => "Healthcare",
      "PERSONAL_CARE"    => "Personal Care",
      "SERVICES"         => "Services",
      "TRANSPORTATION"   => "Transportation",
      "TRAVEL"           => "Travel"
    }

    expectations.each do |code, expected_name|
      matched = @matcher.match(code)
      assert_not_nil matched, "expected '#{code}' to match a default category"
      assert_equal expected_name, matched.name, "'#{code}' mapped to the wrong category"
    end
  end

  test "is case-insensitive on the category code" do
    assert_equal "Travel", @matcher.match("travel")&.name
    assert_equal "Travel", @matcher.match("Travel")&.name
  end

  test "leaves ambiguous or money-movement codes uncategorised" do
    %w[MERCHANDISE RENT_AND_UTILITIES GOVERNMENT_AND_NON_PROFIT TRANSFER_IN TRANSFER_OUT].each do |code|
      assert_nil @matcher.match(code), "expected '#{code}' to have no confident match"
    end
  end

  test "returns nil for unknown or blank codes" do
    assert_nil @matcher.match("NOT_A_REAL_CATEGORY")
    assert_nil @matcher.match(nil)
    assert_nil @matcher.match("")
  end

  test "does not match when the family has none of the target categories" do
    bare_family = families(:dylan_family)
    bare_family.categories.destroy_all
    matcher = RedbarkAccount::Transactions::CategoryMatcher.new(bare_family.categories.reload.to_a)

    assert_nil matcher.match("FOOD_AND_DRINK"), "no Food & Drink category exists, so no match"
  end

  test "matches localized default category names" do
    localized = I18n.t("models.category.defaults.food_and_drink", locale: :uk)
    category = Struct.new(:id, :name).new(1, localized)
    matcher = RedbarkAccount::Transactions::CategoryMatcher.new([ category ], locale: "uk")

    assert_equal localized, matcher.match("FOOD_AND_DRINK")&.name
  end

  test "falls back to merchant_category_code when category is blank" do
    assert_equal "Groceries", @matcher.match(nil, 5411)&.name
    assert_equal "Travel", @matcher.match("", 7011)&.name
  end

  test "falls back to merchant_category_code when category has no confident mapping" do
    # MERCHANDISE is deliberately excluded from CATEGORY_GROUPS; the MCC still resolves.
    assert_equal "Groceries", @matcher.match("MERCHANDISE", 5411)&.name
  end

  test "prefers category over merchant_category_code when both are confident" do
    # 5541 (service stations) maps to Transportation via MCC, but the category code wins.
    assert_equal "Entertainment", @matcher.match("ENTERTAINMENT", 5541)&.name
  end

  test "returns nil when neither category nor merchant_category_code has a confident mapping" do
    assert_nil @matcher.match("TRANSFER_IN", 6011), "ATM withdrawal MCC is money movement, not spending"
    assert_nil @matcher.match(nil, nil)
  end
end
