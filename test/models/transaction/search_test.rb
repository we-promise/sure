require "test_helper"

class Transaction::SearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @checking_account = accounts(:depository)
    @credit_card_account = accounts(:credit_card)
    @loan_account = accounts(:loan)

    # Clean up existing entries/transactions from fixtures to ensure test isolation
    @family.accounts.each { |account| account.entries.delete_all }
  end

  test "search filters by transaction types using kind enum" do
    # Create different types of transactions using the helper method
    standard_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    transfer_entry = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    payment_entry = create_transaction(
      account: @credit_card_account,
      amount: -300,
      kind: "cc_payment"
    )

    loan_payment_entry = create_transaction(
      account: @loan_account,
      amount: 400,
      kind: "loan_payment"
    )

    one_time_entry = create_transaction(
      account: @checking_account,
      amount: 500,
      kind: "one_time"
    )

    # Test transfer type filter (includes loan_payment)
    transfer_results = Transaction::Search.new(@family, filters: { types: [ "transfer" ] }).transactions_scope
    transfer_ids = transfer_results.pluck(:id)

    assert_includes transfer_ids, transfer_entry.entryable.id
    assert_includes transfer_ids, payment_entry.entryable.id
    assert_includes transfer_ids, loan_payment_entry.entryable.id
    assert_not_includes transfer_ids, one_time_entry.entryable.id
    assert_not_includes transfer_ids, standard_entry.entryable.id

    # Test expense type filter (excludes transfer kinds but includes one_time)
    expense_results = Transaction::Search.new(@family, filters: { types: [ "expense" ] }).transactions_scope
    expense_ids = expense_results.pluck(:id)

    assert_includes expense_ids, standard_entry.entryable.id
    assert_includes expense_ids, one_time_entry.entryable.id
    assert_not_includes expense_ids, loan_payment_entry.entryable.id
    assert_not_includes expense_ids, transfer_entry.entryable.id
    assert_not_includes expense_ids, payment_entry.entryable.id

    # Test income type filter
    income_entry = create_transaction(
      account: @checking_account,
      amount: -600,
      kind: "standard"
    )

    income_results = Transaction::Search.new(@family, filters: { types: [ "income" ] }).transactions_scope
    income_ids = income_results.pluck(:id)

    assert_includes income_ids, income_entry.entryable.id
    assert_not_includes income_ids, standard_entry.entryable.id
    assert_not_includes income_ids, loan_payment_entry.entryable.id
    assert_not_includes income_ids, transfer_entry.entryable.id

    # Test combined expense and income filter (excludes transfer kinds but includes one_time)
    non_transfer_results = Transaction::Search.new(@family, filters: { types: [ "expense", "income" ] }).transactions_scope
    non_transfer_ids = non_transfer_results.pluck(:id)

    assert_includes non_transfer_ids, standard_entry.entryable.id
    assert_includes non_transfer_ids, income_entry.entryable.id
    assert_includes non_transfer_ids, one_time_entry.entryable.id
    assert_not_includes non_transfer_ids, loan_payment_entry.entryable.id
    assert_not_includes non_transfer_ids, transfer_entry.entryable.id
    assert_not_includes non_transfer_ids, payment_entry.entryable.id
  end

  test "search category filter handles uncategorized transactions correctly with kind filtering" do
    # Create uncategorized transactions of different kinds
    uncategorized_standard = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    uncategorized_transfer = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    uncategorized_loan_payment = create_transaction(
      account: @loan_account,
      amount: 300,
      kind: "loan_payment"
    )

    # Search for uncategorized transactions
    uncategorized_results = Transaction::Search.new(@family, filters: { categories: [ Category.uncategorized.name ] }).transactions_scope
    uncategorized_ids = uncategorized_results.pluck(:id)

    # Should include standard uncategorized transactions
    assert_includes uncategorized_ids, uncategorized_standard.entryable.id

    # Should exclude all transfer kinds (TRANSFER_KINDS) even if uncategorized
    assert_not_includes uncategorized_ids, uncategorized_transfer.entryable.id
    assert_not_includes uncategorized_ids, uncategorized_loan_payment.entryable.id
  end

  test "filtering for only Uncategorized returns only uncategorized transactions" do
    # Create a mix of categorized and uncategorized transactions
    categorized = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink)
    )

    uncategorized = create_transaction(
      account: @checking_account,
      amount: 200
    )

    # Filter for only uncategorized
    results = Transaction::Search.new(@family, filters: { categories: [ Category.uncategorized.name ] }).transactions_scope
    result_ids = results.pluck(:id)

    # Should only include uncategorized transaction
    assert_includes result_ids, uncategorized.entryable.id
    assert_not_includes result_ids, categorized.entryable.id
    assert_equal 1, result_ids.size
  end

  test "filtering for Uncategorized plus a real category returns both" do
    # Create a travel category for testing
    travel_category = @family.categories.create!(
      name: "Travel",
      color: "#3b82f6",
      classification: "expense"
    )

    # Create transactions with different categories
    food_transaction = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink)
    )

    travel_transaction = create_transaction(
      account: @checking_account,
      amount: 150,
      category: travel_category
    )

    uncategorized = create_transaction(
      account: @checking_account,
      amount: 200
    )

    # Filter for food category + uncategorized
    results = Transaction::Search.new(@family, filters: { categories: [ "Food & Drink", Category.uncategorized.name ] }).transactions_scope
    result_ids = results.pluck(:id)

    # Should include both food and uncategorized
    assert_includes result_ids, food_transaction.entryable.id
    assert_includes result_ids, uncategorized.entryable.id
    # Should NOT include travel
    assert_not_includes result_ids, travel_transaction.entryable.id
    assert_equal 2, result_ids.size
  end

  test "filtering excludes uncategorized when not in filter" do
    # Create a mix of transactions
    categorized = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink)
    )

    uncategorized = create_transaction(
      account: @checking_account,
      amount: 200
    )

    # Filter for only food category (without Uncategorized)
    results = Transaction::Search.new(@family, filters: { categories: [ "Food & Drink" ] }).transactions_scope
    result_ids = results.pluck(:id)

    # Should only include categorized transaction
    assert_includes result_ids, categorized.entryable.id
    assert_not_includes result_ids, uncategorized.entryable.id
    assert_equal 1, result_ids.size
  end

  test "new family-based API works correctly" do
    # Create transactions for testing
    transaction1 = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    transaction2 = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    # Test new family-based API
    search = Transaction::Search.new(@family, filters: { types: [ "expense" ] })
    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should include expense transactions
    assert_includes result_ids, transaction1.entryable.id
    # Should exclude transfer transactions
    assert_not_includes result_ids, transaction2.entryable.id

    # Test that the relation builds from family.transactions correctly
    assert_equal @family.transactions.joins(entry: :account).where(
      "entries.amount >= 0 AND NOT (transactions.kind IN (?))", Transaction::TRANSFER_KINDS
    ).count, results.count
  end

  test "transfer filter includes investment_contribution transactions" do
    investment_contribution = create_transaction(
      account: @checking_account,
      amount: 500,
      kind: "investment_contribution"
    )

    funds_movement = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "funds_movement"
    )

    search = Transaction::Search.new(@family, filters: { types: [ "transfer" ] })
    result_ids = search.transactions_scope.pluck(:id)

    assert_includes result_ids, investment_contribution.entryable.id
    assert_includes result_ids, funds_movement.entryable.id
  end

  test "expense filter excludes investment_contribution transactions" do
    investment_contribution = create_transaction(
      account: @checking_account,
      amount: 500,
      kind: "investment_contribution"
    )

    standard_expense = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    search = Transaction::Search.new(@family, filters: { types: [ "expense" ] })
    result_ids = search.transactions_scope.pluck(:id)

    assert_not_includes result_ids, investment_contribution.entryable.id
    assert_includes result_ids, standard_expense.entryable.id
  end

  test "family-based API requires family parameter" do
    assert_raises(NoMethodError) do
      search = Transaction::Search.new({ types: [ "expense" ] })
      search.transactions_scope  # This will fail when trying to call .transactions on a Hash
    end
  end

  # Totals method tests (lifted from Transaction::TotalsTest)

  test "totals computes basic expense and income totals" do
    # Create expense transaction
    expense_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Create income transaction
    income_entry = create_transaction(
      account: @checking_account,
      amount: -200,
      kind: "standard"
    )

    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 2, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money # $100
    assert_equal Money.new(200, "USD"), totals.income_money  # $200
  end

  test "totals handles multi-currency transactions with exchange rates" do
    # Create EUR transaction
    eur_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      currency: "EUR",
      kind: "standard"
    )

    # Create exchange rate EUR -> USD
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      rate: 1.1,
      date: eur_entry.date
    )

    # Create USD transaction
    usd_entry = create_transaction(
      account: @checking_account,
      amount: 50,
      currency: "USD",
      kind: "standard"
    )

    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 2, totals.count
    # EUR 100 * 1.1 + USD 50 = 110 + 50 = 160
    assert_equal Money.new(160, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals handles missing exchange rates gracefully" do
    # Create EUR transaction without exchange rate
    eur_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      currency: "EUR",
      kind: "standard"
    )

    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 1, totals.count
    # Should use rate of 1 when exchange rate is missing
    assert_equal Money.new(100, "USD"), totals.expense_money # EUR 100 * 1
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals respects category filters" do
    # Create transactions in different categories
    food_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    other_entry = create_transaction(
      account: @checking_account,
      amount: 50,
      category: categories(:income),
      kind: "standard"
    )

    # Filter by food category only
    search = Transaction::Search.new(@family, filters: { categories: [ "Food & Drink" ] })
    totals = search.totals

    assert_equal 1, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money # Only food transaction
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "category filter includes subcategories" do
    # Create a transaction with the parent category
    parent_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Create a transaction with the subcategory (fixture :subcategory has name "Restaurants", parent "Food & Drink")
    subcategory_entry = create_transaction(
      account: @checking_account,
      amount: 75,
      category: categories(:subcategory),
      kind: "standard"
    )

    # Create a transaction with a different category
    other_entry = create_transaction(
      account: @checking_account,
      amount: 50,
      category: categories(:income),
      kind: "standard"
    )

    # Filter by parent category only - should include both parent and subcategory transactions
    search = Transaction::Search.new(@family, filters: { categories: [ "Food & Drink" ] })
    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should include both parent and subcategory transactions
    assert_includes result_ids, parent_entry.entryable.id
    assert_includes result_ids, subcategory_entry.entryable.id
    # Should not include transactions with different category
    assert_not_includes result_ids, other_entry.entryable.id

    # Verify totals also include subcategory transactions
    totals = search.totals
    assert_equal 2, totals.count
    assert_equal Money.new(175, "USD"), totals.expense_money # 100 + 75
  end

  test "totals respects type filters" do
    # Create expense and income transactions
    expense_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    income_entry = create_transaction(
      account: @checking_account,
      amount: -200,
      kind: "standard"
    )

    # Filter by expense type only
    search = Transaction::Search.new(@family, filters: { types: [ "expense" ] })
    totals = search.totals

    assert_equal 1, totals.count
    assert_equal Money.new(100, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "totals handles empty results" do
    search = Transaction::Search.new(@family)
    totals = search.totals

    assert_equal 0, totals.count
    assert_equal Money.new(0, "USD"), totals.expense_money
    assert_equal Money.new(0, "USD"), totals.income_money
  end

  test "category filter handles non-existent category names without SQL error" do
    # Create a transaction with an existing category
    existing_entry = create_transaction(
      account: @checking_account,
      amount: 100,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Search for non-existent category names (parent_category_ids will be empty)
    # This should not cause a SQL error with "IN ()"
    search = Transaction::Search.new(@family, filters: { categories: [ "Non-Existent Category 1", "Non-Existent Category 2" ] })
    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should not include any transactions since categories don't exist
    assert_not_includes result_ids, existing_entry.entryable.id
    assert_equal 0, result_ids.length

    # Verify totals also work without error
    totals = search.totals
    assert_equal 0, totals.count
    assert_equal Money.new(0, "USD"), totals.expense_money
  end

  test "search matches entries name OR notes with ILIKE" do
    # Transaction with matching text in name only
    name_match = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard",
      name: "Grocery Store"
    )

    # Transaction with matching text in notes only
    notes_match = create_transaction(
      account: @checking_account,
      amount: 50,
      kind: "standard",
      name: "Credit Card Payment",
      notes: "Payment of 50 USD at Grocery Mart on 2026-11-01"
    )

    # Transaction with no matching text
    no_match = create_transaction(
      account: @checking_account,
      amount: 75,
      kind: "standard",
      name: "Gas station",
      notes: "Fuel refill"
    )

    search = Transaction::Search.new(
      @family,
      filters: { search: "grocery" }
    )

    results = search.transactions_scope
    result_ids = results.pluck(:id)

    # Should match name
    assert_includes result_ids, name_match.entryable.id

    # Should match notes
    assert_includes result_ids, notes_match.entryable.id

    # Should not match unrelated transactions
    assert_not_includes result_ids, no_match.entryable.id
  end

  test "uncategorized filter returns same results across all supported locales" do
    # Create uncategorized transactions
    uncategorized1 = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    uncategorized2 = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "standard"
    )

    # Create a categorized transaction to ensure filter is working
    categorized = create_transaction(
      account: @checking_account,
      amount: 300,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Get the expected count using English locale (known working case)
    I18n.with_locale(:en) do
      english_uncategorized_name = Category.uncategorized.name
      english_results = Transaction::Search.new(@family, filters: { categories: [ english_uncategorized_name ] }).transactions_scope
      @expected_count = english_results.count
      assert_equal 2, @expected_count, "English locale should return 2 uncategorized transactions"
    end

    # Test every supported locale returns the same count when filtering by that locale's uncategorized name
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        localized_uncategorized_name = Category.uncategorized.name
        results = Transaction::Search.new(@family, filters: { categories: [ localized_uncategorized_name ] }).transactions_scope
        result_count = results.count

        assert_equal @expected_count, result_count,
          "Locale '#{locale}' with uncategorized name '#{localized_uncategorized_name}' should return #{@expected_count} transactions but got #{result_count}"
      end
    end
  end

  test "uncategorized filter works with English parameter name regardless of current locale" do
    # This tests the bug where URL contains English "Uncategorized" but user's locale is different
    # Bug: /transactions/?q[categories][]=Uncategorized fails when locale is French

    # Create uncategorized transactions
    uncategorized1 = create_transaction(
      account: @checking_account,
      amount: 100,
      kind: "standard"
    )

    uncategorized2 = create_transaction(
      account: @checking_account,
      amount: 200,
      kind: "standard"
    )

    # Create a categorized transaction to ensure filter is working
    categorized = create_transaction(
      account: @checking_account,
      amount: 300,
      category: categories(:food_and_drink),
      kind: "standard"
    )

    # Get the English uncategorized name (this is what URLs typically contain)
    english_uncategorized_name = I18n.t("models.category.uncategorized", locale: :en)

    # Get the expected count using English locale (known working case)
    expected_count = nil
    I18n.with_locale(:en) do
      results = Transaction::Search.new(@family, filters: { categories: [ english_uncategorized_name ] }).transactions_scope
      expected_count = results.count
      assert_equal 2, expected_count, "English locale should return 2 uncategorized transactions"
    end

    # Test that using the English parameter name works in every supported locale
    # This catches the bug where French locale fails with English "Uncategorized" parameter
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        # Simulate URL parameter: q[categories][]=Uncategorized (English, regardless of user's locale)
        results = Transaction::Search.new(@family, filters: { categories: [ english_uncategorized_name ] }).transactions_scope
        result_count = results.count

        assert_equal expected_count, result_count,
          "Locale '#{locale}' should return #{expected_count} transactions when filtering with English 'Uncategorized' parameter, but got #{result_count}"
      end
    end
  end
end
