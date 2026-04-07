require "test_helper"

class EntryPersonalAmountTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create! name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new
  end

  test "effective_amount returns amount when personal_amount is nil" do
    entry = create_transaction(account: @account, amount: 80)
    assert_nil entry.personal_amount
    assert_equal 80, entry.effective_amount
  end

  test "effective_amount returns personal_amount when set" do
    entry = create_transaction(account: @account, amount: 80)
    entry.update!(personal_amount: 20)
    assert_equal 20, entry.effective_amount
  end

  test "effective_amount_money returns personal_amount_money when set" do
    entry = create_transaction(account: @account, amount: 80)
    entry.update!(personal_amount: 20)
    assert_equal Money.new(20, "USD"), entry.effective_amount_money
  end

  test "effective_amount_money returns amount_money when personal_amount is nil" do
    entry = create_transaction(account: @account, amount: 80)
    assert_equal Money.new(80, "USD"), entry.effective_amount_money
  end

  test "personal_amount does not affect classification" do
    expense_entry = create_transaction(account: @account, amount: 80)
    expense_entry.update!(personal_amount: 20)
    assert_equal "expense", expense_entry.classification

    income_entry = create_transaction(account: @account, amount: -1000)
    income_entry.update!(personal_amount: -500)
    assert_equal "income", income_entry.classification
  end

  test "personal_amount can be cleared by setting to nil" do
    entry = create_transaction(account: @account, amount: 80)
    entry.update!(personal_amount: 20)
    assert_equal 20, entry.effective_amount

    entry.update!(personal_amount: nil)
    assert_equal 80, entry.effective_amount
  end

  test "income statement uses personal_amount in totals when set" do
    category = @family.categories.create!(name: "Dining")

    # Bank amount: 80, personal share: 20
    entry = create_transaction(account: @account, amount: 80, category: category)
    entry.update!(personal_amount: 20)

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    assert_equal Money.new(20, "USD"), totals.expense_money
  end

  test "income statement uses amount when personal_amount is nil" do
    category = @family.categories.create!(name: "Dining")

    create_transaction(account: @account, amount: 80, category: category)

    income_statement = IncomeStatement.new(@family)
    totals = income_statement.totals(date_range: Period.last_30_days.date_range)

    assert_equal Money.new(80, "USD"), totals.expense_money
  end

  test "personal_amount cannot be greater than amount" do
    entry = create_transaction(account: @account, amount: 80)
    entry.personal_amount = 100
    assert_not entry.valid?
    assert entry.errors[:personal_amount].any?
  end

  test "personal_amount equal to amount is valid" do
    entry = create_transaction(account: @account, amount: 80)
    entry.personal_amount = 80
    assert entry.valid?
  end

  test "setting personal_amount to zero clears it via controller logic" do
    entry = create_transaction(account: @account, amount: 80)
    entry.update!(personal_amount: 20)
    assert_equal 20, entry.personal_amount

    entry.update!(personal_amount: nil)
    assert_nil entry.personal_amount
    assert_equal 80, entry.effective_amount
  end
end
