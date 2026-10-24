require "test_helper"

class RuleGroupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @family = @user.family
    @group = @family.rule_groups.create!(name: "Food")
  end

  test "new" do
    get new_rule_group_url
    assert_response :success
  end

  test "creates a group at the end of the list" do
    assert_difference "RuleGroup.count", 1 do
      post rule_groups_url, params: { rule_group: { name: "Subscriptions" } }
    end

    assert_redirected_to rules_url
    group = @family.rule_groups.find_by!(name: "Subscriptions")
    assert_equal "group:#{group.id}", Rule::Layout.new(@family).items.last.key
  end

  test "rejects a duplicate name" do
    assert_no_difference "RuleGroup.count" do
      post rule_groups_url, params: { rule_group: { name: "Food" } }
    end

    assert_response :unprocessable_entity
  end

  test "renames a group" do
    patch rule_group_url(@group), params: { rule_group: { name: "Groceries" } }

    assert_redirected_to rules_url
    assert_equal "Groceries", @group.reload.name
  end

  test "deletes a group and keeps its rules" do
    rule = create_rule(group: @group)

    assert_difference "RuleGroup.count", -1 do
      delete rule_group_url(@group)
    end

    assert_redirected_to rules_url
    assert_nil rule.reload.rule_group_id
  end

  test "reorders the rules of a group" do
    first = create_rule(group: @group)
    second = create_rule(group: @group)

    patch reorder_rule_group_url(@group), params: { rule_ids: [ second.id, first.id ] }, as: :json

    assert_response :no_content
    assert_equal [ second, first ], @family.rules.where(rule_group: @group).ordered.to_a
  end

  test "reorder rejects rules outside the group" do
    first = create_rule(group: @group)
    outside = create_rule

    patch reorder_rule_group_url(@group), params: { rule_ids: [ first.id, outside.id ] }, as: :json

    assert_response :unprocessable_entity
  end

  test "switches all rules of a group on and off" do
    rule = create_rule(group: @group, active: false)

    patch activation_rule_group_url(@group, active: true)
    assert_redirected_to rules_url
    assert rule.reload.active?

    patch activation_rule_group_url(@group, active: false)
    assert_not rule.reload.active?
  end

  test "groups of another family are not found" do
    foreign = families(:empty).rule_groups.create!(name: "Foreign")

    patch rule_group_url(foreign), params: { rule_group: { name: "Taken" } }
    assert_response :not_found

    patch activation_rule_group_url(foreign, active: true)
    assert_response :not_found
    assert_equal "Foreign", foreign.reload.name
  end

  test "guests cannot change groups" do
    sign_in family_guest

    assert_no_difference "RuleGroup.count" do
      post rule_groups_url, params: { rule_group: { name: "Guest group" } }
    end
    patch activation_rule_group_url(@group, active: true)

    assert_redirected_to accounts_url
  end

  private
    def create_rule(group: nil, active: true)
      @family.rules.create!(resource_type: "transaction", active: active, rule_group: group,
        actions: [ Rule::Action.new(action_type: "exclude_transaction") ])
    end
end
