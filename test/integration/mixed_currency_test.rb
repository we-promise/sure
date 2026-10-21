require "test_helper"

# Every other fixture is USD, so the suite never combines two currencies and
# Money's currency guard would find nothing. This family mixes three: EUR
# family currency, a EUR and a GBP account next to USD ones, and a security
# priced in EUR. Each path below must convert before it adds, subtracts or
# compares.
#
# Strict mode is off here on purpose: syncs and insight generators rescue
# errors broadly, which would swallow a raised mismatch. In report mode every
# mismatch reaches Rails.error, so the tests assert that none was reported.
class MixedCurrencyTest < ActionDispatch::IntegrationTest
  setup do
    @strict_currency = Money.strict_currency?
    Money.strict_currency = false
    Money.reset_reported_mismatches!

    @user = users(:family_admin)
    @family = @user.family
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    @family.update!(currency: "EUR")
    switch_currency(accounts(:depository), "EUR")
    switch_currency(accounts(:credit_card), "GBP")
    Security::Price.where(security: securities(:aapl)).update_all(currency: "EUR")

    rates = { %w[USD EUR] => 0.9, %w[EUR USD] => 1.1, %w[GBP EUR] => 1.2, %w[EUR GBP] => 0.83, %w[USD GBP] => 0.75, %w[GBP USD] => 1.3 }
    rows = ((Date.current - 2.years)..Date.current).flat_map do |date|
      rates.map { |(from, to), rate| { from_currency: from, to_currency: to, date: date, rate: rate } }
    end
    ExchangeRate.upsert_all(rows, unique_by: %i[from_currency to_currency date])
  end

  teardown do
    Money.strict_currency = @strict_currency
    Money.reset_reported_mismatches!
  end

  test "syncs, transfer matching and insights convert before combining amounts" do
    assert_no_currency_mismatch do
      @family.accounts.each do |account|
        syncer = Account::Syncer.new(account)
        syncer.perform_sync(Sync.create!(syncable: account))
        syncer.perform_post_sync
      end
      @family.auto_match_transfers!

      Insight::GeneratorRegistry::GENERATORS.each do |generator|
        generator.new(@family).generate
      end
    end
  end

  test "assistant read functions convert before combining amounts" do
    calls = {
      Assistant::Function::GetAccounts => { "include_balance_series" => true },
      Assistant::Function::GetBalanceSheet => {},
      Assistant::Function::GetHoldings => { "page" => 1 },
      Assistant::Function::GetIncomeStatement => { "start_date" => 1.year.ago.to_date.iso8601, "end_date" => Date.current.iso8601 },
      Assistant::Function::GetTransactions => {},
      Assistant::Function::GetBudget => {},
      Assistant::Function::GetInsights => {},
      Assistant::Function::GetRecurringTransactions => {},
      Assistant::Function::GetValuations => {},
      Assistant::Function::GetBills => {}
    }

    assert_no_currency_mismatch do
      calls.each do |function, params|
        result = function.new(@user).call(params)
        assert_not result.is_a?(Hash) && result.with_indifferent_access[:error].present?, "#{function.name.demodulize} returned an error"
      end
    end
  end

  test "pages convert before combining amounts" do
    sign_in @user

    # The trade page is left out: its unrealized gain still subtracts a cost
    # basis in the trade's currency from a price in the security's. That
    # call site is fixed in a separate change.
    paths = %w[/ /accounts /transactions /reports /reports?period_type=quarterly /plan /goals /bills /insights /recurring_transactions]
    paths << budget_path(Budget.date_to_param(Date.current))
    paths += @family.accounts.map { |account| account_path(account) }
    paths += Holding.where(account: @family.accounts).map { |holding| holding_path(holding) }
    paths += Entry.where(account: @family.accounts, entryable_type: %w[Transaction Valuation]).map do |entry|
      entry.entryable_type == "Transaction" ? transaction_path(entry) : valuation_path(entry)
    end
    paths += @family.goals.map { |goal| goal_path(goal) }

    assert_no_currency_mismatch do
      paths.each do |path|
        get path
        assert_response :success, "GET #{path}"
      end
    end
  end

  test "API reads convert before combining amounts" do
    api_key = ApiKey.create!(user: @user, name: "Mixed currency", scopes: [ "read" ], source: "web",
                             display_key: "mixed_currency_#{SecureRandom.hex(8)}")

    assert_no_currency_mismatch do
      %w[accounts balance_sheet holdings trades transactions insights budgets recurring_transactions balances valuations].each do |resource|
        get "/api/v1/#{resource}", headers: api_headers(api_key)
        assert_response :success, "GET /api/v1/#{resource}"
      end
    end
  end

  test "the probe sees a mismatch in report mode" do
    reports = capture_error_reports(Money::CurrencyMismatchError) { Money.new(200, :usd) - Money.new(180, :eur) }

    assert_equal 1, reports.size, "the probe must be able to see a mismatch, or the tests above prove nothing"
  end

  private
    def switch_currency(account, currency)
      account.update_columns(currency: currency)
      account.entries.update_all(currency: currency)
      account.balances.update_all(currency: currency)
    end

    def assert_no_currency_mismatch(&block)
      reports = capture_error_reports(Money::CurrencyMismatchError, &block)
      assert_empty reports.map { |report| "#{report.error.message} at #{report.context[:call_site]}" }
    end
end
