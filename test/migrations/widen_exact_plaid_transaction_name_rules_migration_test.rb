# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260908120000_widen_exact_plaid_transaction_name_rules")

# The migration rewrites user-authored rules, so what it does and does not touch
# is the whole of its correctness. It cannot be undone.
class WidenExactPlaidTransactionNameRulesMigrationTest < ActiveSupport::TestCase
  setup do
    # dylan_family owns plaid_items(:one), so its rules are in scope.
    @rule = rules(:one)
    @plaid_family = families(:dylan_family)
    @family_without_plaid = families(:empty)

    assert @plaid_family.plaid_items.any?, "fixture expectation: dylan_family has a Plaid connection"
    assert_empty @family_without_plaid.plaid_items, "fixture expectation: empty family has none"
  end

  test "an exact name condition becomes a contains condition" do
    condition = create_condition(operator: "=", value: "Target")

    run_migration

    assert_equal "like", condition.reload.operator
    assert_equal "Target", condition.value, "the value the user wrote is left alone"
  end

  # The silent-inversion case: `!= "Target"` currently excludes Target, and would
  # start including it once the name grows past the compared value.
  test "a not-equal name condition becomes a does-not-contain condition" do
    condition = create_condition(operator: "!=", value: "Target")

    run_migration

    assert_equal "not_like", condition.reload.operator
  end

  test "conditions that already use substring matching are untouched" do
    like = create_condition(operator: "like", value: "Target")
    not_like = create_condition(operator: "not_like", value: "Target")

    run_migration

    assert_equal "like", like.reload.operator
    assert_equal "not_like", not_like.reload.operator
  end

  # Only the name is changing. An exact match on any other field still means
  # exactly what it did.
  test "conditions on other fields keep their operator" do
    condition = create_condition(operator: "=", value: "100", condition_type: "transaction_amount")

    run_migration

    assert_equal "=", condition.reload.operator
  end

  # No Plaid connection means no name change, so there is nothing to preserve
  # and no reason to widen what the user asked for.
  test "a family without a Plaid connection is left alone" do
    # Saved without validation: `min_actions` requires an action, which has no
    # bearing on a migration that only rewrites rule_conditions. The rule
    # fixtures are actionless for the same reason.
    other_rule = Rule.new(family: @family_without_plaid, resource_type: "transaction")
    other_rule.save!(validate: false)

    condition = other_rule.conditions.create!(
      condition_type: "transaction_name", operator: "=", value: "Target"
    )

    run_migration

    assert_equal "=", condition.reload.operator
  end

  # Sub-conditions carry parent_id and leave rule_id null, so reaching them needs
  # a separate branch in the query.
  test "a nested sub-condition is reached through its parent" do
    parent = @rule.conditions.create!(condition_type: "compound", operator: "and")
    nested = parent.sub_conditions.create!(
      condition_type: "transaction_name", operator: "=", value: "Target"
    )

    run_migration

    assert_equal "like", nested.reload.operator
  end

  private
    def create_condition(operator:, value:, condition_type: "transaction_name")
      @rule.conditions.create!(condition_type: condition_type, operator: operator, value: value)
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        WidenExactPlaidTransactionNameRules.new.up
      end
    end
end
