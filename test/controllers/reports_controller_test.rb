require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "index renders successfully" do
    get reports_path
    assert_response :ok
  end

  test "index with monthly period" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert_select "h1", text: I18n.t("reports.index.title")
  end

  test "index with quarterly period" do
    get reports_path(period_type: :quarterly)
    assert_response :ok
  end

  test "index with ytd period" do
    get reports_path(period_type: :ytd)
    assert_response :ok
  end

  test "index with custom period and date range" do
    get reports_path(
      period_type: :custom,
      start_date: 1.month.ago.to_date.to_s,
      end_date: Date.current.to_s
    )
    assert_response :ok
  end

  test "export generates CSV" do
    get export_reports_path(
      period_type: :monthly,
      start_date: Date.current.beginning_of_month.to_s,
      end_date: Date.current.end_of_month.to_s,
      format: :csv
    )
    assert_response :ok
    assert_equal "text/csv", response.media_type
    assert_match /reports_monthly_\d{8}\.csv/, response.headers["Content-Disposition"]
  end

  test "index shows empty state when no transactions" do
    # Delete all transactions for the family by deleting from accounts
    @family.accounts.each { |account| account.entries.destroy_all }

    get reports_path
    assert_response :ok
    assert_select "h3", text: I18n.t("reports.empty_state.title")
  end

  test "index with budget performance for current month" do
    # Create a budget for current month
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    category = @family.categories.expenses.first

    if category && budget
      # Find or create budget category to avoid duplicate errors
      budget_category = budget.budget_categories.find_or_initialize_by(category: category)
      budget_category.budgeted_spending = Money.new(50000, @family.currency)
      budget_category.save!
    end

    get reports_path(period_type: :monthly)
    assert_response :ok
  end

  test "index calculates summary metrics correctly" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert assigns(:summary_metrics).present?
    assert assigns(:summary_metrics)[:current_income].is_a?(Money)
    assert assigns(:summary_metrics)[:current_expenses].is_a?(Money)
    assert assigns(:summary_metrics)[:net_savings].is_a?(Money)
  end

  test "index builds comparison data" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert assigns(:comparison_data).present?
    assert assigns(:comparison_data)[:current].present?
    assert assigns(:comparison_data)[:previous].present?
  end

  test "index builds trends data" do
    get reports_path(period_type: :monthly)
    assert_response :ok
    assert assigns(:trends_data).present?
    assert assigns(:trends_data).is_a?(Array)
  end

  test "index handles invalid date parameters gracefully" do
    get reports_path(
      period_type: :custom,
      start_date: "invalid-date",
      end_date: "also-invalid"
    )
    assert_response :ok # Should not crash, uses defaults
  end
end
