require "test_helper"

class IncomeStatement::FinancialSummaryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create! name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new
    @month = Date.new(2024, 2, 1)
  end

  test "uses server reporting rules and exact decimal amounts" do
    create_transaction(account: @account, amount: -1000, date: @month)
    create_transaction(account: @account, amount: 12.345.to_d, date: @month)
    create_transaction(account: @account, amount: -20, date: @month, kind: "loan_payment")
    create_transaction(account: @account, amount: 900, date: @month, kind: "cc_payment")
    create_transaction(account: @account, amount: 800, date: @month, excluded: true)
    pending = create_transaction(account: @account, amount: 700, date: @month)
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })
    result = summary
    assert_equal "1000.0", result[:income]
    assert_equal "32.345", result[:spending]
    assert_equal "967.655", result[:net_savings]
    assert_equal "32.345", result[:spending_comparison][:current_total]
    assert_equal "96.7655", result[:savings_rate]
  end

  test "fills every day and compares current month to the same elapsed day" do
    create_transaction(account: @account, amount: 10, date: Date.new(2024, 1, 10))
    create_transaction(account: @account, amount: 90, date: Date.new(2024, 1, 31))
    result = summary(as_of: Date.new(2024, 2, 15))[:spending_comparison]
    assert_equal 15, result[:current].size
    assert_equal 31, result[:previous].size
    assert_equal "10.0", result[:comparison_total]
    assert_equal "100.0", result[:previous].last[:amount]
    assert_equal "2024-01-15", result[:comparison_end_date]
  end

  test "historical leap month retains full previous month and null rate without income" do
    result = summary
    assert_nil result[:savings_rate]
    assert_equal 29, result[:spending_comparison][:current].size
    assert_equal 31, result[:spending_comparison][:previous].size
    assert_equal "2024-01-31", result[:spending_comparison][:comparison_end_date]
  end

  test "rejects future and nonfirst month" do
    assert_raises(ArgumentError) { summary(month: Date.new(2025, 1, 1)) }
    assert_raises(ArgumentError) { summary(month: Date.new(2024, 2, 2)) }
  end

  test "does not include another family" do
    create_transaction(account: accounts(:depository), amount: 100, date: @month)
    assert_equal "0.0", summary[:spending]
  end

  test "reports FX-converted values without rounding to currency minor units" do
    eur = @family.accounts.create!(name: "EUR", currency: "EUR", balance: 0, accountable: Depository.new)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @month, rate: "1.2345")
    create_transaction(account: eur, currency: "EUR", amount: 10, date: @month)
    assert_equal "12.345", summary[:spending]
    assert_equal "12.345", summary[:spending_comparison][:current_total]
  end

  test "savings rate may be negative and currency remains attached" do
    @family.update!(currency: "JPY")
    @account.update!(currency: "JPY")
    create_transaction(account: @account, currency: "JPY", amount: -100, date: @month)
    create_transaction(account: @account, currency: "JPY", amount: 150, date: @month)
    assert_equal "JPY", summary[:currency]
    assert_equal "-50.0", summary[:savings_rate]
  end

  private
    def summary(month: @month, as_of: Date.new(2024, 3, 5))
      IncomeStatement::FinancialSummary.new(IncomeStatement.new(@family), month: month, as_of: as_of).as_json
    end
end
