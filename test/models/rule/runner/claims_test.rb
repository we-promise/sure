require "test_helper"

class Rule::Runner::ClaimsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Claims test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @tag = @family.tags.create!(name: "Tag")
    @whole_foods = create_transaction(account: @account, name: "Whole Foods Market").transaction
    @other = create_transaction(account: @account, name: "Hardware store").transaction
    @claims = Rule::Runner::Claims.new
  end

  test "a rule claims the attributes it sets on its matches" do
    rule = create_rule(Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id))

    @claims.record(rule, [ @whole_foods.id ])

    assert_equal Set[@whole_foods.id], @claims.claimed_ids[:category_id]
    assert_empty @claims.stopped_ids
  end

  test "a rule that stops processing hides its matches from the rules below" do
    rule = create_rule(Rule::Action.new(action_type: "set_transaction_tags", value: [ @tag.id ]), stop_processing: true)
    below = create_rule(Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id), value: "")

    assert_equal [ @whole_foods.id, @other.id ].sort, @claims.unstopped_scope(below).pluck(:id).sort

    @claims.record(rule, [ @whole_foods.id ])

    assert_equal Set[@whole_foods.id], @claims.stopped_ids
    assert_equal [ @other.id ], @claims.unstopped_scope(below).pluck(:id)
  end

  test "claims and stops from several rules add up" do
    first = create_rule(Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id), stop_processing: true)
    second = create_rule(Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id), value: "Hardware", stop_processing: true)

    @claims.record(first, [ @whole_foods.id ])
    @claims.record(second, [ @other.id ])

    assert_equal Set[@whole_foods.id, @other.id], @claims.claimed_ids[:category_id]
    assert_equal Set[@whole_foods.id, @other.id], @claims.stopped_ids
  end

  test "tags claim nothing" do
    rule = create_rule(Rule::Action.new(action_type: "set_transaction_tags", value: [ @tag.id ]))

    @claims.record(rule, [ @whole_foods.id ])

    assert_empty @claims.claimed_ids
  end

  test "an action that cannot be resolved claims nothing and does not raise" do
    rule = create_rule(Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id))
    rule.actions.first.update_column(:action_type, "unknown_action")

    @claims.record(rule.reload, [ @whole_foods.id ])

    assert_empty @claims.claimed_ids
  end

  private
    def create_rule(action, value: "Whole Foods", stop_processing: false)
      conditions = value.present? ? [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: value) ] : []
      @family.rules.create!(resource_type: "transaction", active: true, stop_processing: stop_processing,
        conditions: conditions, actions: [ action ])
    end
end
