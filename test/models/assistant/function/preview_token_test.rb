require "test_helper"

class Assistant::Function::PreviewTokenTest < ActiveSupport::TestCase
  # A rule tool that confirms its own write with a preview, as a delete_rule
  # would. It declares no token purpose of its own.
  class ConfirmRule < Assistant::Function
    include Assistant::Function::RuleSupport

    def self.name
      "confirm_rule"
    end

    def call(params = {})
      rule = find_rule(params["rule_id"])
      confirm_with_preview(params, rule, -> { { rule_id: rule.id } }, done_key: :done) { { success: true, done: true } }
    end
  end

  setup do
    @user = users(:family_admin)
    @rule = @user.family.rules.create!(
      resource_type: "transaction",
      conditions_attributes: [ { condition_type: "transaction_name", operator: "like", value: "zxq coffee" } ],
      actions_attributes: [ { action_type: "set_transaction_category", value: categories(:food_and_drink).id } ]
    )
    @tool = ConfirmRule.new(@user)
  end

  test "a rule tool accepts the token from its own preview" do
    token = @tool.call("rule_id" => @rule.id)[:preview_token]

    assert_equal true, @tool.call("rule_id" => @rule.id, "preview_token" => token)[:done]
  end

  test "a rule tool refuses a token minted for apply_rule" do
    token = Assistant::Function::PreviewRule.new(@user).call("rule_id" => @rule.id)[:preview][:preview_token]
    assert token.present?

    assert_equal "preview_required", @tool.call("rule_id" => @rule.id, "preview_token" => token)[:error]
  end

  test "apply_rule refuses a token another rule tool minted for itself" do
    token = @tool.call("rule_id" => @rule.id)[:preview_token]

    result = Assistant::Function::ApplyRule.new(@user).call("rule_id" => @rule.id, "preview_token" => token)

    assert_equal "preview_required", result[:error]
    assert_not @rule.reload.active
  end
end
