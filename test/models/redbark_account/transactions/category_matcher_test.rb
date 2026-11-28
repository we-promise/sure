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

  # The family's locale and the default locale are not the only ones a persisted
  # default category name can be in: bootstrap uses the member's locale.
  test "matches a default category persisted in another supported locale" do
    ukrainian = I18n.t("models.category.defaults.food_and_drink", locale: :uk)
    assert_not_equal I18n.t("models.category.defaults.food_and_drink", locale: :en), ukrainian
    category = Struct.new(:id, :name).new(1, ukrainian)
    matcher = RedbarkAccount::Transactions::CategoryMatcher.new([ category ], locale: "en")

    assert_equal ukrainian, matcher.match("FOOD_AND_DRINK")&.name
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
    # Redbark sends a supermarket shop as FOOD_AND_DRINK + 5411. The category code still
    # decides; splitting groceries out is left to a user rule on the stored MCC.
    assert_equal "Food & Drink", @matcher.match("FOOD_AND_DRINK", 5411)&.name
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

  # Redbark sends credit-card repayments as LOAN_PAYMENTS with no MCC, so this matcher
  # cannot tell one from a mortgage or personal-loan repayment. It categorises both, and
  # that is safe for the card case: when the card is linked, transfer detection classifies
  # the payment as a cc_payment, which Transaction::BUDGET_EXCLUDED_KINDS keeps out of
  # budget analytics regardless of the category sitting on it.
  test "categorises loan and credit-card repayments" do
    assert_equal "Loan Payments", @matcher.match("LOAN_PAYMENTS")&.name
    assert_equal "Loan Payments", @matcher.match("LOAN_PAYMENTS", nil)&.name
  end

  test "falls back to merchant_category_code for an unrecognized category code" do
    # Unknown codes take the fallback path, not just blank and deliberately excluded ones.
    # This is also what would happen to every API v2 `provider_category` value.
    assert_equal "Groceries", @matcher.match("NOT_A_REAL_CATEGORY", 5411)&.name
  end

  test "reads a zero-padded merchant_category_code as base 10" do
    # Parsed as octal, "05411" would be 2825 (no match) and "05712" would be 3018, inside
    # the 3000-3299 airline range, i.e. Travel instead of Shopping.
    assert_equal "Groceries", @matcher.match("MERCHANDISE", "05411")&.name
    assert_equal "Shopping", @matcher.match("MERCHANDISE", "05712")&.name
  end

  # The table is keyed on Redbark API v1 `category` codes. The v2 migration (#4311)
  # replaces that field with `provider_category`, whose values are different; because an
  # unrecognized code silently falls through to the MCC table, that switch would degrade
  # this matcher to MCC-only without any error. Pin the v1 codes so it fails here instead.
  test "is keyed on Redbark API v1 category codes" do
    v1_codes = %w[
      BANK_FEES ENTERTAINMENT FOOD_AND_DRINK GOVERNMENT_AND_NON_PROFIT HOME_IMPROVEMENT
      INCOME LOAN_PAYMENTS MEDICAL MERCHANDISE PERSONAL_CARE RENT_AND_UTILITIES SERVICES
      TRANSFER_IN TRANSFER_OUT TRANSPORTATION TRAVEL
    ]

    assert_equal 16, v1_codes.size, "Redbark v1 defines 16 fixed category codes"
    mapped = RedbarkAccount::Transactions::CategoryTaxonomy::CATEGORY_GROUPS.keys
    assert_empty mapped - v1_codes, "CATEGORY_GROUPS must only contain documented v1 codes"
  end

  # These exercise the shared Transactions::MccTaxonomy table, so they guard Monobank's
  # matcher too. The schemes separate a telecom service from telecom hardware, and a
  # sport the cardholder watches from one they take part in.
  test "maps telephone equipment sales to Shopping, not Utilities" do
    # 4812 is telecom equipment and telephone sales; the phone bill is 4814.
    assert_equal "Shopping", @matcher.match("MERCHANDISE", 4812)&.name
    assert_equal "Utilities", @matcher.match("MERCHANDISE", 4814)&.name
  end

  test "maps professional sports to Entertainment, not Sports & Fitness" do
    # 7941 is commercial sports, professional clubs and promoters -- match tickets.
    assert_equal "Entertainment", @matcher.match("MERCHANDISE", 7941)&.name
    # 7997 is membership/athletic/country clubs, i.e. a gym subscription, which stays.
    assert_equal "Sports & Fitness", @matcher.match("MERCHANDISE", 7997)&.name
  end

  test "leaves digital goods unmapped" do
    # 5815 covers digital books, films and music, as often bought outright as subscribed
    # to, so neither Subscriptions nor Shopping is an honest guess.
    assert_nil @matcher.match("MERCHANDISE", 5815)
  end
end
