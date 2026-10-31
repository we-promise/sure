require "test_helper"

# Proves the IncomeStatement::ScopedTransactionsQuery refactor preserves
# behavior: each refactored query class must return exactly what its
# pre-refactor implementation returned. The legacy implementations are
# verbatim copies from main (test/support/legacy_income_statement_*.rb), and
# each test runs both over the same data across the class's full option
# matrix (account scoping, trade inclusion, stats interval).
class IncomeStatement::ScopedTransactionsQueryEquivalenceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)

    @checking = @family.accounts.create! name: "Checking", currency: "USD", balance: 5000, accountable: Depository.new
    @savings = @family.accounts.create! name: "Savings", currency: "USD", balance: 1000, accountable: Depository.new
    @eur = @family.accounts.create! name: "EUR Checking", currency: "EUR", balance: 1000, accountable: Depository.new
    @retirement = @family.accounts.create! name: "401k", currency: "USD", balance: 10000, accountable: Investment.new(subtype: "401k")
    @unreported = @family.accounts.create! name: "Off the books", currency: "USD", balance: 100, accountable: Depository.new, exclude_from_reports: true

    @food = @family.categories.create! name: "Food"
    @groceries = @family.categories.create! name: "Groceries", parent: @food

    # Spread across two calendar months (and weeks) so interval grouping varies.
    create_transaction(account: @checking, amount: 100, date: 40.days.ago.to_date, category: @food)
    create_transaction(account: @checking, amount: 50, date: 5.days.ago.to_date, category: @groceries)
    create_transaction(account: @checking, amount: -500, date: 5.days.ago.to_date) # income
    create_transaction(account: @checking, amount: -200, date: 5.days.ago.to_date, kind: "loan_payment")
    create_transaction(account: @checking, amount: -300, date: 5.days.ago.to_date, kind: "investment_contribution")
    create_transaction(account: @checking, amount: 30, date: 5.days.ago.to_date, kind: "funds_movement") # budget-excluded kind
    create_transaction(account: @checking, amount: 25, date: 5.days.ago.to_date, excluded: true)

    transfer = create_transaction(account: @checking, amount: 60, date: 5.days.ago.to_date)
    transfer.entryable.update!(investment_activity_label: "Transfer")

    pending = create_transaction(account: @checking, amount: 20, date: 5.days.ago.to_date)
    pending.entryable.update!(extra: { "simplefin" => { "pending" => true } })

    create_transaction(account: @savings, amount: 75, date: 10.days.ago.to_date)

    ExchangeRate.create! from_currency: "EUR", to_currency: "USD", date: 5.days.ago.to_date, rate: 2
    create_transaction(account: @eur, amount: 40, currency: "EUR", date: 5.days.ago.to_date)
    create_transaction(account: @eur, amount: 10, currency: "EUR", date: 10.days.ago.to_date) # no rate row, falls back to 1

    create_transaction(account: @retirement, amount: 300, date: 5.days.ago.to_date) # tax-advantaged, excluded
    create_transaction(account: @unreported, amount: 45, date: 5.days.ago.to_date) # exclude_from_reports, excluded

    @period = Period.custom(start_date: 45.days.ago.to_date, end_date: Date.current)
  end

  test "Totals matches its pre-refactor implementation across its option matrix" do
    [ true, false ].each do |include_trades|
      account_id_options.each do |included_account_ids|
        args = { transactions_scope: transactions_scope, date_range: @period.date_range,
                 include_trades: include_trades, included_account_ids: included_account_ids }

        assert_equal_rows(
          LegacyIncomeStatementTotals.new(@family, **args).call,
          IncomeStatement::Totals.new(@family, **args).call,
          "Totals (include_trades: #{include_trades}, included_account_ids: #{included_account_ids.inspect})"
        )
      end
    end
  end

  test "DailyExpenseTotals matches its pre-refactor implementation across its option matrix" do
    account_id_options.each do |included_account_ids|
      args = { transactions_scope: transactions_scope, date_range: @period.date_range,
               included_account_ids: included_account_ids }

      assert_equal_rows(
        LegacyIncomeStatementDailyExpenseTotals.new(@family, **args).call,
        IncomeStatement::DailyExpenseTotals.new(@family, **args).call,
        "DailyExpenseTotals (included_account_ids: #{included_account_ids.inspect})"
      )
    end
  end

  test "FamilyStats matches its pre-refactor implementation across its option matrix" do
    %w[month week].each do |interval|
      account_id_options.each do |account_ids|
        assert_equal_rows(
          LegacyIncomeStatementFamilyStats.new(@family, interval: interval, account_ids: account_ids).call,
          IncomeStatement::FamilyStats.new(@family, interval: interval, account_ids: account_ids).call,
          "FamilyStats (interval: #{interval}, account_ids: #{account_ids.inspect})"
        )
      end
    end
  end

  test "CategoryStats matches its pre-refactor implementation across its option matrix" do
    %w[month week].each do |interval|
      account_id_options.each do |account_ids|
        assert_equal_rows(
          LegacyIncomeStatementCategoryStats.new(@family, interval: interval, account_ids: account_ids).call,
          IncomeStatement::CategoryStats.new(@family, interval: interval, account_ids: account_ids).call,
          "CategoryStats (interval: #{interval}, account_ids: #{account_ids.inspect})"
        )
      end
    end
  end

  private
    # Unscoped, scoped to a subset of accounts, and scoped to nothing.
    def account_id_options
      [ nil, [ @checking.id, @savings.id ], [] ]
    end

    # Same production scope used by the dashboard for both implementations.
    def transactions_scope
      @family.transactions.visible.excluding_pending.in_period(@period)
    end

    def assert_equal_rows(legacy_rows, refactored_rows, label)
      assert_equal normalize(legacy_rows), normalize(refactored_rows), "#{label} returned different rows"
    end

    # Row order is not guaranteed by GROUP BY, so compare order-insensitively.
    def normalize(rows)
      rows.map(&:to_h).sort_by(&:inspect)
    end
end
