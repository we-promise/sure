require "test_helper"

class InvestmentStatement::HistoricalScopeTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "includes disabled investment accounts and excludes other types and excluded accounts" do
    active = create_account(accountable: Investment.new)
    crypto = create_account(accountable: Crypto.new)
    disabled = create_account(accountable: Investment.new)
    disabled.update!(status: "disabled", disabled_at: 3.days.ago)
    depository = create_account(accountable: Depository.new)
    excluded = create_account(accountable: Investment.new)
    excluded.update!(exclude_from_reports: true)
    deleted = create_account(accountable: Investment.new)
    deleted.update!(status: "pending_deletion")

    scope = InvestmentStatement::HistoricalScope.new(@family)

    assert_equal [ active.id, crypto.id, disabled.id ].sort, scope.account_ids.sort
    assert_not_includes scope.account_ids, depository.id
    assert_not_includes scope.account_ids, excluded.id
    assert_not_includes scope.account_ids, deleted.id
  end

  test "active_until_dates covers only disabled accounts, cut off the day before disabling" do
    active = create_account(accountable: Investment.new)
    disabled = create_account(accountable: Investment.new)
    disabled_on = 3.days.ago
    disabled.update!(status: "disabled", disabled_at: disabled_on)

    dates = InvestmentStatement::HistoricalScope.new(@family).active_until_dates

    assert_equal [ disabled.id ], dates.keys
    assert_equal disabled_on.to_date - 1.day, dates[disabled.id]
    assert_nil dates[active.id]
  end

  test "includes draft investment accounts" do
    draft = create_account(accountable: Investment.new)
    draft.update!(status: "draft")

    scope = InvestmentStatement::HistoricalScope.new(@family)

    assert_includes scope.account_ids, draft.id
    assert_nil scope.active_until_dates[draft.id], "a draft account has no cut-off"
  end

  test "a disabled account without disabled_at is cut off the day before it was last updated" do
    disabled = create_account(accountable: Investment.new)
    disabled.update!(status: "disabled", disabled_at: nil)
    disabled.update_column(:updated_at, 5.days.ago)

    dates = InvestmentStatement::HistoricalScope.new(@family).active_until_dates

    assert_equal 5.days.ago.to_date - 1.day, dates[disabled.reload.id]
  end

  test "with a user, an account shared without include_in_finances is out of scope" do
    shared_user = users(:new_email)
    owned = create_account(accountable: Investment.new)
    owned.update!(owner: shared_user)
    shared_excluded = create_account(accountable: Investment.new)
    shared_excluded.share_with!(shared_user, permission: "read_only", include_in_finances: false)

    scope = InvestmentStatement::HistoricalScope.new(@family, user: shared_user)

    assert_equal [ owned.id ], scope.account_ids

    # Without the user, both accounts are in scope
    assert_equal [ owned.id, shared_excluded.id ].sort,
      InvestmentStatement::HistoricalScope.new(@family).account_ids.sort
  end

  test "accounts are loaded once per instance" do
    create_account(accountable: Investment.new)
    scope = InvestmentStatement::HistoricalScope.new(@family)

    queries = capture_sql_queries do
      scope.accounts
      scope.account_ids
      scope.active_until_dates
    end

    assert_equal 1, queries.grep(/FROM "accounts"/).size
  end

  private
    def create_account(accountable:, balance: 1000, currency: "USD")
      @family.accounts.create!(
        name: "Account #{SecureRandom.hex(3)}",
        balance: balance,
        cash_balance: 0,
        currency: currency,
        accountable: accountable
      )
    end
end
