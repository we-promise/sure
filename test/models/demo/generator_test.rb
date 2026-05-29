require "test_helper"

class Demo::GeneratorTest < ActiveSupport::TestCase
  test "generate_retirement! seeds a populated plan for the family owner" do
    family = families(:empty)
    assert_not family.goals.where(type: "Goal::Retirement").exists?

    Demo::Generator.new.send(:generate_retirement!, family)

    plan = family.goals.find_by(type: "Goal::Retirement")
    assert plan, "expected a Goal::Retirement to be created"
    assert_equal family.users.order(:created_at).first.id, plan.user_id
    assert_equal 2, plan.pension_sources.count
    assert_equal 3, plan.statements.count
    assert_equal 2, plan.adjustments.count
  end

  test "generate_retirement! is idempotent" do
    family = families(:empty)
    Demo::Generator.new.send(:generate_retirement!, family)
    assert_no_difference -> { family.goals.where(type: "Goal::Retirement").count } do
      Demo::Generator.new.send(:generate_retirement!, family)
    end
  end
end
