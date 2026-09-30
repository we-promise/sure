require "test_helper"

class AccountableSparklinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "should get show for depository" do
    get accountable_sparkline_url("depository")
    assert_response :success
  end

  test "show does not trigger auto-sync" do
    Sync.destroy_all
    Family.any_instance.expects(:sync_later).never

    get accountable_sparkline_url("depository")

    assert_response :success
  end

  test "show echoes the requesting sidebar frame id" do
    get accountable_sparkline_url("depository"), headers: { "Turbo-Frame" => "mobile_tab_depository_sparkline_0123456789ab" }

    assert_response :success
    assert_select "turbo-frame#mobile_tab_depository_sparkline_0123456789ab", count: 1
    assert_select "#mobile_tab_depository_sparkline_0123456789ab_chart", count: 1
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
