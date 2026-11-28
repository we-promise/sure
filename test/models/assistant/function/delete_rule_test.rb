require "test_helper"

class Assistant::Function::DeleteRuleTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::DeleteRule.new(@user)
    @category = categories(:food_and_drink)

    @rule = @family.rules.create!(
      name: "Coffee",
      resource_type: "transaction",
      active: false,
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
  end

  test "deletes an inactive rule with its conditions, actions and runs, and returns what it deleted" do
    @rule.rule_runs.create!(execution_type: "manual", status: "success", transactions_queued: 1, transactions_processed: 1, transactions_modified: 1, executed_at: Time.current)
    condition_ids = @rule.conditions.ids
    action_ids = @rule.actions.ids

    result = @fn.call("rule_id" => @rule.id)

    assert result[:success], result.inspect
    assert result[:deleted]
    assert_equal @rule.id, result.dig(:rule, :id)
    assert_equal "Coffee", result.dig(:rule, :name)
    assert_equal "set_transaction_category", result.dig(:rule, :actions, 0, :action_type)
    assert_match "Rule 'Coffee' deleted", result[:message]

    assert_not Rule.exists?(@rule.id)
    assert_empty Rule::Condition.where(id: condition_ids)
    assert_empty Rule::Action.where(id: action_ids)
    assert_empty RuleRun.where(rule_id: @rule.id)
  end

  test "refuses an active rule and leaves it in place" do
    @rule.update!(active: true)

    result = @fn.call("rule_id" => @rule.id)

    assert_equal false, result[:success]
    assert_equal "rule_active", result[:error]
    assert_match "update_rule active: false", result[:message]
    assert Rule.exists?(@rule.id)
  end

  test "re-checks active under the lock, so a rule activated after the lookup is kept" do
    stale = @family.rules.find(@rule.id)
    Rule.where(id: @rule.id).update_all(active: true)
    @fn.stubs(:find_rule).returns(stale)

    assert_equal "rule_active", @fn.call("rule_id" => @rule.id)[:error]
    assert Rule.exists?(@rule.id)
  end

  test "a rule deleted by another call after the lookup is not found" do
    stale = @family.rules.find(@rule.id)
    @rule.destroy!
    @fn.stubs(:find_rule).returns(stale)

    assert_equal "not_found", @fn.call("rule_id" => @rule.id)[:error]
  end

  test "refuses while a rule run holds the family lock and leaves the rule in place" do
    # Transactional tests share one PG session, and a session can re-take its
    # own advisory lock, so holding it needs a separate connection.
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    other = PG.connect({
      dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username] || config[:user], password: config[:password]
    }.compact)
    other.exec("SELECT pg_advisory_lock(#{Rule::Runner.advisory_lock_key(@family.id)})")

    result = @fn.call("rule_id" => @rule.id)

    assert_equal "rules_running", result[:error]
    assert Rule.exists?(@rule.id)
  ensure
    other&.close
  end

  test "another family's rule is not found and left untouched" do
    foreign = families(:empty).rules.create!(
      name: "Theirs",
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_name", value: "x" } ]
    )

    assert_equal "not_found", @fn.call("rule_id" => foreign.id)[:error]
    assert Rule.exists?(foreign.id)
  end

  test "unknown and malformed ids are not found" do
    [ "00000000-0000-0000-0000-000000000000", "not-a-uuid", "", nil ].each do |id|
      assert_equal "not_found", @fn.call("rule_id" => id)[:error]
    end
    assert Rule.exists?(@rule.id)
  end
end
