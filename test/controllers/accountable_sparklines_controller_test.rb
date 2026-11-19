require "test_helper"

class AccountableSparklinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get show for depository" do
    get accountable_sparkline_url("depository")
    assert_response :success
  end

  test "show renders an empty series without a trend" do
    empty_series = Series.new(
      start_date: 1.day.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: []
    )
    Rails.cache.clear
    Balance::ChartSeriesBuilder.any_instance.expects(:balance_series).returns(empty_series)

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_select "p.font-mono", count: 0
  end

  test "group sparkline only includes accounts the user can access" do
    member = users(:family_member)
    sign_in member
    Rails.cache.clear

    requested_account_ids = nil
    Balance::ChartSeriesBuilder.expects(:new).with do |args|
      requested_account_ids = args[:account_ids]
    end.returns(stub(balance_series: empty_series))

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_includes requested_account_ids, accounts(:depository).id
    assert_not_includes requested_account_ids, accounts(:connected).id
    assert_equal member.accessible_accounts.visible.where(accountable_type: "Depository").pluck(:id).sort,
                 requested_account_ids.sort
  end

  test "group sparkline cache is not shared between users with different access" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    get accountable_sparkline_url("depository")
    assert_response :success

    sign_in users(:family_member)

    requested_account_ids = nil
    Balance::ChartSeriesBuilder.expects(:new).with do |args|
      requested_account_ids = args[:account_ids]
    end.returns(stub(balance_series: empty_series))

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_not_nil requested_account_ids, "member must not be served the admin's cached series"
    assert_not_includes requested_account_ids, accounts(:connected).id
  end

  test "group sparkline cache is invalidated when account sharing changes" do
    member = users(:family_member)
    sign_in member
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    get accountable_sparkline_url("depository")
    assert_response :success

    AccountShare.create!(account: accounts(:connected), user: member, permission: "read_only", include_in_finances: true)

    requested_account_ids = nil
    Balance::ChartSeriesBuilder.expects(:new).with do |args|
      requested_account_ids = args[:account_ids]
    end.returns(stub(balance_series: empty_series))

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_includes requested_account_ids, accounts(:connected).id
  end

  test "group sparkline cache is invalidated when account ownership moves without a share change" do
    member = users(:family_member)
    sign_in member
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)

    get accountable_sparkline_url("depository")
    assert_response :success

    # Same write as User#reassign_owned_accounts!: no share row and no account
    # timestamp changes, but the member now owns (and can see) the account.
    Account.where(id: accounts(:connected).id).update_all(owner_id: member.id)

    requested_account_ids = nil
    Balance::ChartSeriesBuilder.expects(:new).with do |args|
      requested_account_ids = args[:account_ids]
    end.returns(stub(balance_series: empty_series))

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_includes requested_account_ids, accounts(:connected).id
  end

  test "group sparkline cache is invalidated when a share is replaced without a newer timestamp" do
    member = users(:family_member)
    sign_in member
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    shared_at = 1.hour.ago
    AccountShare.where(user: member).update_all(updated_at: shared_at)

    get accountable_sparkline_url("depository")
    assert_response :success

    # Share count and newest updated_at stay the same, the accessible set does not.
    AccountShare.where(user: member, account: accounts(:credit_card)).delete_all
    AccountShare.insert_all([
      { account_id: accounts(:connected).id, user_id: member.id, permission: "read_only",
        include_in_finances: true, created_at: shared_at, updated_at: shared_at }
    ])

    requested_account_ids = nil
    Balance::ChartSeriesBuilder.expects(:new).with do |args|
      requested_account_ids = args[:account_ids]
    end.returns(stub(balance_series: empty_series))

    get accountable_sparkline_url("depository")

    assert_response :success
    assert_includes requested_account_ids, accounts(:connected).id
  end

  test "linked investment sparkline does not load full account records" do
    AccountProvider.create!(
      account: accounts(:investment),
      provider: snaptrade_accounts(:fidelity_401k)
    )

    Rails.cache.clear

    queries = capture_sql_queries do
      get accountable_sparkline_url("investment")
    end

    assert_response :success
    assert_match(/SELECT .*"accounts"\."id".*"account_providers"\."id" FROM "accounts"/, queries.join("\n"))
    assert_empty queries.grep(/SELECT "accounts"\.\* FROM "accounts"/)
    assert_empty queries.grep(/SELECT 1 AS one FROM "accounts".*JOIN "account_providers"/)
    assert_empty queries.grep(/SELECT (DISTINCT )?"accounts"\."id" FROM "accounts" .*"accounts"\."accountable_type" =/)
  end

  test "sparkline skips accounts excluded from reports" do
    accounts(:connected).update!(exclude_from_reports: true)

    account_ids = sparkline_account_ids("depository")

    assert_includes account_ids, accounts(:depository).id
    assert_not_includes account_ids, accounts(:connected).id
  end

  test "sparkline skips shared accounts not included in the member's finances" do
    sign_in users(:family_member)
    account_shares(:depository_shared_with_member).update!(include_in_finances: false)

    assert_not_includes sparkline_account_ids("depository"), accounts(:depository).id
  end

  test "sparkline cache follows the member's finance setting" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in users(:family_member)
    share = account_shares(:depository_shared_with_member)

    assert_includes sparkline_account_ids("depository"), accounts(:depository).id

    # Only the share changes, so the family's data-update timestamps stay put.
    share.update_columns(include_in_finances: false)

    assert_not_includes sparkline_account_ids("depository", clear_cache: false), accounts(:depository).id
  end

  private
    def empty_series
      Series.new(start_date: 1.day.ago.to_date, end_date: Date.current, interval: "1 day", values: [])
    end

    def sparkline_account_ids(accountable_key, clear_cache: true)
      Rails.cache.clear if clear_cache
      account_ids = nil
      builder = mock("chart_series_builder")
      builder.stubs(:balance_series).returns(empty_series)
      Balance::ChartSeriesBuilder.expects(:new).with { |args| account_ids = args[:account_ids]; true }.returns(builder)

      get accountable_sparkline_url(accountable_key)

      assert_response :success
      account_ids
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end
end
