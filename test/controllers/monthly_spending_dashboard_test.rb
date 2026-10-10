require "test_helper"

class MonthlySpendingDashboardTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "preview block renders after money flow with responsive chart and category details" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    get_monthly_home
    assert_response :success
    assert_select "#monthly-spending-section", count: 1
    assert_select "[data-controller='DS--monthly-spending-chart']", count: 1
    assert_select "#monthly-spending-section table"
    assert_select "#monthly-spending-section input[name='monthly_spending_account_ids[]'][type=hidden]", count: 1
  end

  test "feature and hidden list are absent without personal preview access" do
    @user.update!(preferences: { "preview_features_enabled" => false, "hidden_sections" => [ "monthly_spending" ] })
    IncomeStatement::MonthlySpending.expects(:new).never
    get root_url, params: { customize: "true" }
    assert_response :success
    assert_select "#monthly-spending-section", count: 0
    assert_select "[value='monthly_spending']", count: 0
  end

  test "empty and invalid filters never show unfiltered bars" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    get_monthly_home params: { monthly_spending_account_ids: [ "" ] }
    assert_response :success
    assert_select "#monthly-spending-section [data-controller='DS--monthly-spending-chart']", count: 0
    get_monthly_home params: { monthly_spending_from: "invalid" }
    assert_response :success
    assert_select "#monthly-spending-section [data-controller='DS--monthly-spending-chart']", count: 0
    assert_select "#monthly-spending-section [role='status']"
  end

  test "single digit month is normalized without silently changing the period" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    travel_to Date.new(2026, 10, 10) do
      create_transaction(account: accounts(:depository), date: Date.new(2025, 2, 1), amount: 25)
      get_monthly_home params: { monthly_spending_from: "2025-2", monthly_spending_to: "2025-04" }
      assert_response :success
      assert_select "select[name='monthly_spending_from_month'] option[selected][value='2']"
      assert_select "select[name='monthly_spending_from_year'] option[selected][value='2025']"
      assert_select "[data-monthly-spending-total]", count: 3
      assert_select "[data-monthly-spending-total='2025-02-01']"
    end
  end

  test "invalid range retains date and account selections for correction" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    travel_to Date.new(2026, 10, 10) do
      get_monthly_home params: {
        monthly_spending_from_year: "2026", monthly_spending_from_month: "2",
        monthly_spending_to_year: "2025", monthly_spending_to_month: "11",
        monthly_spending_account_ids: [ "" ]
      }
      assert_response :success
      assert_select "select[name='monthly_spending_from_month'] option[selected][value='2']"
      assert_select "select[name='monthly_spending_from_year'] option[selected][value='2026']"
      assert_select "select[name='monthly_spending_to_month'] option[selected][value='11']"
      assert_select "input[name='monthly_spending_account_ids[]'][checked]", count: 0
      assert_select "[data-monthly-spending-total]", count: 0
    end
  end

  test "applying filters persists per user and reset restores defaults" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    post monthly_spending_filters_path, params: {
      monthly_spending_from_year: "2025", monthly_spending_from_month: "2",
      monthly_spending_to_year: "2025", monthly_spending_to_month: "4",
      monthly_spending_period: "last_twelve", monthly_spending_account_ids: [ "" ]
    }
    assert_response :see_other
    follow_redirect!
    load_monthly_frame
    assert_select "select[name='monthly_spending_from_month'] option[selected][value='2']"
    assert_equal "custom", @user.reload.preferences.dig("monthly_spending_filters", "period")
    get_monthly_home
    assert_select "select[name='monthly_spending_from_year'] option[selected][value='2025']"
    assert_select "input[name='monthly_spending_account_ids[]'][checked]", count: 0
    other = users(:family_member)
    assert_nil other.preferences&.[]("monthly_spending_filters")
    post monthly_spending_filters_path, params: { reset: "true" }
    follow_redirect!
    load_monthly_frame
    assert_nil @user.reload.preferences["monthly_spending_filters"]
  end

  test "saved rolling period moves across the year and invalid drafts do not replace it" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    travel_to Date.new(2025, 12, 10) do
      post monthly_spending_filters_path, params: { monthly_spending_period: "last_twelve", monthly_spending_account_ids: [ "" ] }
      assert_response :see_other
      assert_equal "last_twelve", @user.reload.preferences.dig("monthly_spending_filters", "period")
    end
    travel_to Date.new(2026, 1, 10) do
      get_monthly_home
      assert_select "select[name='monthly_spending_from_month'] option[selected][value='2']"
      assert_select "select[name='monthly_spending_to_year'] option[selected][value='2026']"
      saved = @user.reload.preferences["monthly_spending_filters"].deep_dup
      post monthly_spending_filters_path, params: { monthly_spending_from: "2026-12", monthly_spending_to: "2026-01" }
      follow_redirect!
      load_monthly_frame
      assert_select "#monthly-spending-section [role='status']"
      assert_equal saved, @user.reload.preferences["monthly_spending_filters"]
    end
  end

  test "saved year presets use the household date when the server has entered a new year" do
    @user.update!(preferences: { "preview_features_enabled" => true })
    @user.family.update!(timezone: "America/Los_Angeles")
    travel_to Time.utc(2026, 1, 1, 1) do
      post monthly_spending_filters_path, params: { monthly_spending_period: "this_year" }
      assert_response :see_other
      saved = @user.reload.preferences["monthly_spending_filters"]
      assert_equal "this_year", saved["period"]
      assert_equal "2025-01", saved["from"]
      assert_equal "2025-12", saved["to"]

      get_monthly_home
      assert_response :success
      assert_select "select[name='monthly_spending_from_year'] option[selected][value='2025']"
      assert_select "select[name='monthly_spending_to_month'] option[selected][value='12']"
      assert_not_includes response.body, I18n.t("pages.dashboard.monthly_spending.invalid_filters")
    end
  end

  test "saving filters requires personal preview access" do
    @user.update!(preferences: { "preview_features_enabled" => false })
    post monthly_spending_filters_path, params: { monthly_spending_period: "last_twelve" }
    assert_response :not_found
    assert_nil @user.reload.preferences["monthly_spending_filters"]
  end

  private
    def get_monthly_home(params: {})
      get root_url, params: params
      load_monthly_frame
    end

    def load_monthly_frame
      frame = css_select("turbo-frame#monthly_spending_chart[src]").first
      get frame["src"] if frame
    end
end
