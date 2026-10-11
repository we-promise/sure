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

  test "activates and applies the rule with a token from its preview" do
    entry = create_transaction(name: "ZXQ Coffee Shop")

    result = perform_enqueued_jobs(only: RuleJob) do
      @fn.call("rule_id" => @rule.id, "preview_token" => preview_token)
    end

    assert result[:success], result.inspect
    assert_equal 1, result[:applied_to]
    assert @rule.reload.active
    assert_equal @category, entry.entryable.reload.category
    assert_equal 1, @rule.rule_runs.count
  end

  test "the match count from get_rules alone cannot apply a rule" do
    create_transaction(name: "ZXQ Coffee Shop")
    match_count = Assistant::Function::GetRules.new(@user).call("rule_id" => @rule.id)[:rule][:match_count]
    assert_equal 1, match_count

    [ nil, "", match_count.to_s, "forged--token" ].each do |token|
      assert_no_enqueued_jobs only: RuleJob do
        assert_equal "preview_required", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
      end
    end
    assert_not @rule.reload.active
  end

  test "a preview without sample transactions issues no token" do
    create_transaction(name: "ZXQ Coffee Shop")

    preview = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id, "sample_size" => 0)[:preview]

    assert_equal 1, preview[:match_count]
    assert_nil preview[:preview_token]
  end

  test "refuses a token once the matches change, and returns a fresh one" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token
    create_transaction(name: "ZXQ Coffee Bar")

    result = nil
    assert_no_enqueued_jobs(only: RuleJob) { result = @fn.call("rule_id" => @rule.id, "preview_token" => token) }

    assert_equal "preview_stale", result[:error]
    assert_equal 2, result[:preview][:match_count]
    assert_not @rule.reload.active

    assert @fn.call("rule_id" => @rule.id, "preview_token" => result[:preview][:preview_token])[:success]
  end

  test "refuses a token once the rule is edited, even with the same match count" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token
    Assistant::Function::UpdateRule.new(@user).call(
      "rule_id" => @rule.id,
      "actions" => [ { "action_type" => "set_transaction_category", "value" => categories(:income).id } ]
    )

    assert_equal "preview_stale", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    assert_not @rule.reload.active
  end

  test "refuses an expired token, another rule's token and another user's token" do
    create_transaction(name: "ZXQ Coffee Shop")
    token = preview_token

    other_rule = @family.rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: @category.id } ]
    )
    assert_equal "preview_required", @fn.call("rule_id" => other_rule.id, "preview_token" => token)[:error]

    other_user = users(:family_member)
    assert_equal "preview_required",
      Assistant::Function::ApplyRule.new(other_user).call("rule_id" => @rule.id, "preview_token" => token)[:error]

    travel Assistant::Function::RuleSupport::PREVIEW_TOKEN_TTL + 1.minute do
      assert_equal "preview_required", @fn.call("rule_id" => @rule.id, "preview_token" => token)[:error]
    end
  end

  test "keeps hand-set values unless override_locked" do
    entry = create_transaction(name: "ZXQ Coffee Shop")
    entry.entryable.lock_attr!(:category_id)

    perform_enqueued_jobs(only: RuleJob) do
      @fn.call("rule_id" => @rule.id, "preview_token" => preview_token)
    end
    assert_nil entry.entryable.reload.category_id

    perform_enqueued_jobs(only: RuleJob) do
      @fn.call("rule_id" => @rule.id, "preview_token" => preview_token, "override_locked" => true)
    end
    assert_equal @category, entry.entryable.reload.category
  end

  test "refuses rules with AI-backed actions, unknown ids and another family's rules" do
    foreign = families(:empty).rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq" } ],
      actions_attributes: [ { action_type: "set_transaction_name", value: "x" } ]
    )
    assert_equal "not_found", @fn.call("rule_id" => foreign.id, "preview_token" => "x")[:error]
    assert_not foreign.reload.active
    assert_equal "not_found", @fn.call("rule_id" => "nope", "preview_token" => "x")[:error]

    @rule.actions.create!(action_type: "auto_categorize")
    assert_equal "ai_action", @fn.call("rule_id" => @rule.id, "preview_token" => "x")[:error]
  end

  private
    def preview_token
      token = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id)[:preview][:preview_token]
      assert token, "a preview of a saved rule should issue a token"
      token
    end
end
