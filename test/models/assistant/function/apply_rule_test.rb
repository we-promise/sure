require "test_helper"

class Assistant::Function::ApplyRuleTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::ApplyRule.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "activates and applies the rule when the count matches" do
    entry = create_transaction(name: "ZXQ Coffee Shop")

    result = perform_enqueued_jobs(only: RuleJob) do
      @fn.call("rule_id" => @rule.id, "expected_count" => 1)
    end

    assert result[:success], result.inspect
    assert @rule.reload.active
    assert_equal @category, entry.entryable.reload.category
    assert_equal 1, @rule.rule_runs.count
  end

  test "refuses a stale count and applies nothing" do
    create_transaction(name: "ZXQ Coffee Shop")
    create_transaction(name: "ZXQ Coffee Bar")

    assert_no_enqueued_jobs only: RuleJob do
      result = @fn.call("rule_id" => @rule.id, "expected_count" => 1)

      assert_equal "count_mismatch", result[:error]
      assert_equal 2, result[:preview][:match_count]
    end

    assert_not @rule.reload.active
  end

  test "keeps hand-set values unless override_locked" do
    entry = create_transaction(name: "ZXQ Coffee Shop")
    entry.entryable.lock_attr!(:category_id)

    perform_enqueued_jobs(only: RuleJob) do
      @fn.call("rule_id" => @rule.id, "expected_count" => 1)
    end
    assert_nil entry.entryable.reload.category_id

    perform_enqueued_jobs(only: RuleJob) do
      @fn.call("rule_id" => @rule.id, "expected_count" => 1, "override_locked" => true)
    end
    assert_equal @category, entry.entryable.reload.category
  end

  test "refuses rules with AI-backed actions and bad arguments" do
    @rule.actions.create!(action_type: "auto_categorize")

    assert_equal "ai_action", @fn.call("rule_id" => @rule.id, "expected_count" => 0)[:error]
    assert_equal "not_found", @fn.call("rule_id" => "nope", "expected_count" => 0)[:error]
  end

  test "requires an integer expected_count" do
    assert_equal "invalid_arguments", @fn.call("rule_id" => @rule.id, "expected_count" => "lots")[:error]
  end
end
