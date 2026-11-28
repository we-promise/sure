require "test_helper"

class Rule::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @active = create_rule("Active rule", active: true)
    @inactive = create_rule("Inactive rule", active: false)
    @scope = @family.rules.where(id: [ @active, @inactive ])
  end

  test "without filters returns the scope it is given" do
    assert_equal [ @active, @inactive ].sort_by(&:id), Rule::Search.new(@scope).rules_scope.sort_by(&:id)
  end

  test "filters by active status" do
    assert_equal [ @active ], Rule::Search.new(@scope, filters: { active: true }).rules_scope.to_a
    assert_equal [ @inactive ], Rule::Search.new(@scope, filters: { active: false }).rules_scope.to_a
  end

  test "filters by resource type" do
    matching = Rule::Search.new(@scope, filters: { resource_type: "transaction" }).rules_scope

    assert_equal [ @active, @inactive ].sort_by(&:id), matching.sort_by(&:id)
    assert_empty Rule::Search.new(@scope.where.not(resource_type: "transaction"), filters: { resource_type: "transaction" }).rules_scope
  end

  test "never widens the scope it is given" do
    assert_empty Rule::Search.new(@scope.where(id: @inactive), filters: { active: true }).rules_scope
  end

  private

    def create_rule(name, active:)
      rule = @family.rules.build(name:, resource_type: "transaction", active:)
      rule.conditions.build(condition_type: "transaction_name", operator: "like", value: name)
      rule.actions.build(action_type: "set_transaction_name", value: name)
      rule.tap(&:save!)
    end
end
