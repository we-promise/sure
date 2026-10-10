require "test_helper"

class IncomeStatement::MonthlySpendingTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:empty)
    @family = @user.family
    @account = @family.accounts.create!(name: "Checking", owner: @user, currency: "USD", balance: 0, accountable: Depository.new)
    @statement = IncomeStatement.new(@family, user: @user)
    @today = Date.new(2025, 1, 10)
    @root = @family.categories.create!(name: "Food", color: "#f97316", lucide_icon: "utensils")
    @child = @family.categories.create!(name: "Groceries", color: "#f97316", lucide_icon: "shopping-cart", parent: @root)
  end

  test "fills empty months across year boundaries and combines child and root categories" do
    create_transaction(account: @account, amount: 30, date: "2024-12-01", category: @root)
    create_transaction(account: @account, amount: 20, date: "2024-12-31", category: @child)
    create_transaction(account: @account, amount: 10, date: @today)
    result = spending(from: "2024-11-01", to: "2025-01-01")
    assert_equal [ "2024-11-01", "2024-12-01", "2025-01-01" ], result[:months].pluck(:month)
    assert_equal [ "0.0", "50.0", "10.0" ], result[:months].pluck(:total)
    assert_equal [ false, false, true ], result[:months].pluck(:partial)
    assert_equal [ { id: @root.id, amount: "50.0" } ], result[:months][1][:categories]
    assert_equal Category::UNCATEGORIZED_FILTER_VALUE, result[:months].last[:categories].first[:id]
  end

  test "uses posted gross expense rules without netting refunds or including future entries" do
    create_transaction(account: @account, amount: 100, date: @today, category: @root)
    create_transaction(account: @account, amount: -20, date: @today, category: @root)
    create_transaction(account: @account, amount: -30, date: @today, kind: "investment_contribution")
    create_transaction(account: @account, amount: -40, date: @today, kind: "loan_payment")
    %w[funds_movement cc_payment one_time].each { |kind| create_transaction(account: @account, amount: 900, date: @today, kind: kind) }
    create_transaction(account: @account, amount: 900, date: @today + 1)
    create_transaction(account: @account, amount: 900, date: @today, excluded: true)
    pending = create_transaction(account: @account, amount: 900, date: @today)
    pending.entryable.update!(extra: { simplefin: { pending: true } })
    assert_equal "170.0", spending[:months].last[:total]
    assert_equal "2025-01-10", spending[:period][:end_date]
  end

  test "empty account and category selections stay empty and do not query totals" do
    create_transaction(account: @account, amount: 100, date: @today)
    [ { account_ids: [] }, { account_ids: [ "" ] }, { category_ids: [] } ].each do |params|
      result = spending(**params)
      assert result[:empty_selection]
      assert result[:months].all? { |month| month[:total] == "0.0" }
    end
  end

  test "filters roots including children while uncategorized remains separately selectable" do
    create_transaction(account: @account, amount: 30, date: @today, category: @child)
    create_transaction(account: @account, amount: 70, date: @today)
    assert_equal "30.0", spending(category_ids: [ @root.id ])[:months].last[:total]
    assert_equal "70.0", spending(category_ids: [ Category::UNCATEGORIZED_FILTER_VALUE ])[:months].last[:total]
  end

  test "converts exact decimal amounts and flags only selected expenses with missing rates" do
    eur = @family.accounts.create!(name: "EUR", owner: @user, currency: "EUR", balance: 0, accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @today, rate: 2)
    create_transaction(account: eur, currency: "EUR", amount: "10.01", date: @today, category: @root)
    create_transaction(account: eur, currency: "EUR", amount: "5.00", date: @today - 1)
    create_transaction(account: eur, currency: "EUR", amount: -900, date: @today - 1)
    result = spending
    assert_equal "25.02", result[:months].last[:total]
    assert_equal 1, result[:missing_exchange_rates]
    assert_equal 0, spending(category_ids: [ @root.id ])[:missing_exchange_rates]
  end

  test "rejects invalid periods and unavailable or malformed filters instead of falling back" do
    [ { from: "2025-01-02" }, { to: "2025-02-01" }, { from: "2025-02-01" },
      { from: "2021-01-01" }, { from: "2024-13-01" }, { from: "0000-01-01" },
      { account_ids: [ accounts(:depository).id ] }, { category_ids: [ categories(:food_and_drink).id ] },
      { account_ids: "all" }, { category_ids: [ 123 ] } ].each do |params|
      assert_raises(IncomeStatement::MonthlySpending::InvalidSelection) { spending(**params) }
    end
    assert_equal 36, spending(from: "2022-02-01")[:months].size
  end

  test "excludes accounts not in the user's finances or reports" do
    other = @family.users.create!(email: "monthly-other@example.com", password: "password123")
    shared = @family.accounts.create!(name: "Shared", owner: other, currency: "USD", balance: 0, accountable: Depository.new)
    shared.account_shares.create!(user: @user, permission: "read_only", include_in_finances: false)
    excluded = @family.accounts.create!(name: "Excluded", owner: @user, exclude_from_reports: true, currency: "USD", balance: 0, accountable: Depository.new)
    [ shared, excluded ].each { |account| create_transaction(account: account, amount: 900, date: @today) }
    create_transaction(account: @account, amount: 10, date: @today)
    result = spending
    assert_equal "10.0", result[:months].last[:total]
    assert_equal [ @account.id ], result[:accounts].pluck(:id)
    assert_raises(IncomeStatement::MonthlySpending::InvalidSelection) { spending(account_ids: [ shared.id ]) }
  end

  private
    def spending(**params)
      IncomeStatement::MonthlySpending.new(@statement, params: params, as_of: @today).as_json
    end
end
