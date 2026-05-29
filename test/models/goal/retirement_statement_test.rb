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
end
