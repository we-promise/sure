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
    assert_empty queries.grep(/SELECT "accounts"\."id" FROM "accounts" WHERE "accounts"\."family_id" = .*"accounts"\."status" IN .*"accounts"\."accountable_type" =/)
  end

  private
    def empty_series
      Series.new(start_date: 1.day.ago.to_date, end_date: Date.current, interval: "1 day", values: [])
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
