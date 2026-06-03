require "test_helper"

class Retirement::StatementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @user.family.update!(retirement_disabled: false)
    sign_in @user
    ensure_tailwind_build
    @plan = Goal::Retirement.for_owner(@user)
    @source = pension_sources(:de_grv_bob)
  end

  test "404 when family retirement disabled" do
    @user.family.update!(retirement_disabled: true)
    get new_retirement_statement_url
    assert_response :not_found
  end

  test "new renders the form" do
    get new_retirement_statement_url
    assert_response :success
  end

  test "create logs a statement" do
    assert_difference -> { @plan.statements.count }, 1 do
      post retirement_statements_url, params: { goal_retirement_statement: {
        pension_source_id: @source.id, received_on: "2026-01-15",
        projected_monthly_amount: 1600, projected_currency: "EUR",
        projected_at_age: 67, current_points: 10.2, raw_source_doc: "Renteninformation 2026"
      } }
    end
    assert_redirected_to retirement_path
  end

  test "destroy soft-deletes (keeps the audit row)" do
    statement = goal_retirement_statements(:grv_2025)
    assert_no_difference -> { Goal::RetirementStatement.unscoped.count } do
      delete retirement_statement_url(statement)
    end
    assert statement.reload.deleted
    assert_redirected_to retirement_path
  end
end
