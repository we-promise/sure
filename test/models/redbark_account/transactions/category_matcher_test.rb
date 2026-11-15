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
    %w[LOAN_PAYMENTS MERCHANDISE RENT_AND_UTILITIES GOVERNMENT_AND_NON_PROFIT TRANSFER_IN TRANSFER_OUT].each do |code|
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

  test "does not let merchant_category_code override a recognized category with no local equivalent" do
    bare_family = families(:dylan_family)
    bare_family.categories.destroy_all
    bare_family.categories.create!(name: "Groceries")
    matcher = RedbarkAccount::Transactions::CategoryMatcher.new(bare_family.categories.reload.to_a)

    # 5411 (supermarket) would resolve to Groceries via MCC, but ENTERTAINMENT is a
    # recognized, non-excluded category code -- it must not fall through to MCC just
    # because the family has no "Entertainment" category.
    assert_nil matcher.match("ENTERTAINMENT", 5411)
  end

  test "reads a zero-padded merchant_category_code as base 10" do
    # Parsed as octal, "05411" would be 2825 (no match) and "05712" would be 3018, inside
    # the 3000-3299 airline range, i.e. Travel instead of Shopping.
    assert_equal "Groceries", @matcher.match("MERCHANDISE", "05411")&.name
    assert_equal "Shopping", @matcher.match("MERCHANDISE", "05712")&.name
  end

  # Redbark sends credit-card repayments as LOAN_PAYMENTS with no MCC. Those are money
  # movement between the user's own accounts, so they must not be categorised as spending.
  test "leaves credit-card repayments uncategorised" do
    assert_nil @matcher.match("LOAN_PAYMENTS")
    assert_nil @matcher.match("LOAN_PAYMENTS", nil)
  end

  test "refines a recognized category with a more specific MCC in the same domain" do
    # Redbark reports a supermarket shop as FOOD_AND_DRINK + 5411. The MCC is sharper
    # about the same spend, so it narrows Food & Drink to Groceries.
    assert_equal "Groceries", @matcher.match("FOOD_AND_DRINK", 5411)&.name
    assert_equal "Groceries", @matcher.match("FOOD_AND_DRINK", "5411")&.name
  end

  test "keeps the category when a permitted refinement has no local equivalent" do
    bare_family = families(:dylan_family)
    bare_family.categories.destroy_all
    bare_family.categories.create!(name: "Food & Drink")
    matcher = RedbarkAccount::Transactions::CategoryMatcher.new(bare_family.categories.reload.to_a)

    # No Groceries category to narrow to, so the broader category code still applies.
    assert_equal "Food & Drink", matcher.match("FOOD_AND_DRINK", 5411)&.name
  end

  test "does not refine a recognized category with an unrelated MCC" do
    # 7011 (lodging) maps to Travel, which is not a permitted refinement of FOOD_AND_DRINK,
    # so the category code decides and the MCC is ignored.
    assert_equal "Food & Drink", @matcher.match("FOOD_AND_DRINK", 7011)&.name
    # 5811 (caterers) maps to Food & Drink itself -- also not a narrowing, so no change.
    assert_equal "Food & Drink", @matcher.match("FOOD_AND_DRINK", 5811)&.name
  end
end
