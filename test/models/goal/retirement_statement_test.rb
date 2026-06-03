require "test_helper"

class Goal::RetirementStatementTest < ActiveSupport::TestCase
  setup do
    @statement = goal_retirement_statements(:grv_2025)
  end

  test "fixture is valid" do
    assert @statement.valid?, @statement.errors.full_messages.to_sentence
  end

  test "default scope excludes soft-deleted rows" do
    @statement.update_column(:deleted, true)
    assert_not Goal::RetirementStatement.exists?(@statement.id)
    assert Goal::RetirementStatement.unscoped.exists?(@statement.id)
  end

  test "points_delta is nil for earliest, signed for later" do
    assert_nil goal_retirement_statements(:grv_2023).points_delta
    assert_in_delta 2.50, goal_retirement_statements(:grv_2025).points_delta, 0.001
  end

  test "soft_replace! soft-deletes self and inserts replacement" do
    new_stmt = nil
    assert_difference -> { Goal::RetirementStatement.unscoped.count }, 1 do
      new_stmt = @statement.soft_replace!(projected_monthly_amount: 1600)
    end

    assert @statement.reload.deleted
    assert_equal 1600, new_stmt.projected_monthly_amount.to_i
    assert_not new_stmt.deleted
  end

  test "money uses projected_currency" do
    assert_equal Money.new(1510, "EUR"), @statement.projected_monthly_amount_money
  end

  test "rejects a pension source from another plan (IDOR guard)" do
    other_plan = Goal::Retirement.create!(
      family: families(:dylan_family), owner: users(:family_member),
      name: "Other plan", currency: "USD"
    )
    other_source = other_plan.pension_sources.create!(
      name: "Foreign", kind: "state", country: "DE", pension_system: "de_grv",
      tax_treatment: "de_renten", payout_shape: "monthly_for_life", start_age: 67, amount: 1, currency: "EUR"
    )

    statement = goals(:retirement_bob).statements.new(
      pension_source: other_source, received_on: Date.current,
      projected_monthly_amount: 100, projected_currency: "EUR"
    )

    assert_not statement.valid?
    assert_includes statement.errors.attribute_names, :pension_source
  end
end
