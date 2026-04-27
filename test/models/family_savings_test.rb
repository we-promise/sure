require "test_helper"

class FamilySavingsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "has_many savings_goals" do
    assert_respond_to @family, :savings_goals
    assert_includes @family.savings_goals, savings_goals(:vacation)
  end

  test "has_many savings_contributions through savings_goals" do
    assert_respond_to @family, :savings_contributions
    assert_includes @family.savings_contributions, savings_contributions(:vacation_initial)
  end
end
