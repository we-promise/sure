require "test_helper"

class Rule::HealthTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Health test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @tag = @family.tags.create!(name: "Tag")

    @woolworths = create_transaction(account: @account, name: "Woolworths").transaction
    @metro = create_transaction(account: @account, name: "Woolworths Metro").transaction
    @uber = create_transaction(account: @account, name: "Uber Eats").transaction
    @hardware = create_transaction(account: @account, name: "Hardware store").transaction
  end

  test "rules with the same conditions and actions are duplicates, whatever the case and spacing of a contains condition" do
    first = create_rule(name_condition("like", "woolworths"), category: @groceries)
    second = create_rule(name_condition("like", "  WOOLWORTHS "), category: @groceries)
    create_rule(name_condition("like", "uber"), category: @groceries)

    assert_equal [ [ first, second ] ], health.duplicates
  end

  test "an AND group reads like the same conditions listed flat" do
    flat = create_rule(name_condition("like", "woolworths"), amount_condition, category: @groceries)
    grouped = create_rule(
      Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [ amount_condition, name_condition("like", "woolworths") ]),
      category: @groceries
    )

    assert_equal [ [ flat, grouped ] ], health.duplicates
  end

  test "rules with different effective dates are not duplicates" do
    create_rule(name_condition("like", "woolworths"), category: @groceries)
    create_rule(name_condition("like", "woolworths"), category: @groceries, effective_date: 1.month.ago.to_date)

    assert_empty health.duplicates
  end

  test "an equals condition keeps its case" do
    create_rule(name_condition("=", "Uber"), category: @groceries)
    create_rule(name_condition("=", "uber"), category: @groceries)

    assert_empty health.duplicates
  end

  test "a pattern is compared exactly as written" do
    create_rule(name_condition("matches_regex", "\\d+"), category: @groceries)
    create_rule(name_condition("matches_regex", "\\D+"), category: @groceries)
    create_rule(name_condition("matches_regex", "^Wool  worths"), category: @groceries)
    create_rule(name_condition("matches_regex", "^Wool worths"), category: @groceries)

    assert_empty health.duplicates
  end

  test "rules with the same conditions that set a field to different values conflict, and the higher active one wins" do
    higher = create_rule(name_condition("like", "woolworths"), category: @groceries)
    lower = create_rule(name_condition("like", "Woolworths"), category: @dining)

    conflict = health.conflicts.sole
    assert_equal [ higher, lower ], conflict.rules
    assert_equal :category_id, conflict.attribute
    assert_equal higher, conflict.winner

    higher.update!(active: false)

    assert_equal lower, health.conflicts.sole.winner
  end

  test "a rule below a stop rule that matches the same transactions is shadowed" do
    stop = create_rule(name_condition("like", "woolworths"), tags: [ @tag ], stop_processing: true)
    below = create_rule(name_condition("like", "metro"), category: @dining)

    entry = health.shadowed.sole
    assert_equal below, entry.rule
    assert_equal :stopped, entry.reason
    assert_equal [ stop ], entry.by

    stop.update!(stop_processing: false)

    assert_empty health.shadowed
  end

  test "a rule whose field a rule above already sets on every match is shadowed" do
    above = create_rule(name_condition("like", "woolworths"), category: @groceries)
    below = create_rule(name_condition("like", "metro"), category: @dining)

    entry = health.shadowed.sole
    assert_equal below, entry.rule
    assert_equal :claimed, entry.reason
    assert_equal [ above ], entry.by
    assert_equal [ :category_id ], entry.attributes
  end

  test "a rule that only adds tags is not shadowed, since tags claim nothing" do
    create_rule(name_condition("like", "woolworths"), category: @groceries)
    create_rule(name_condition("like", "metro"), tags: [ @tag ])

    assert_empty health.shadowed
  end

  test "a rule that sets a field on some matches a rule above also sets is an overlap" do
    above = create_rule(name_condition("like", "woolworths"), category: @groceries)
    below = create_rule(
      Rule::Condition.new(condition_type: "compound", operator: "or", sub_conditions: [ name_condition("like", "metro"), name_condition("like", "hardware") ]),
      category: @dining
    )

    overlap = health.overlaps.sole
    assert_equal [ below, above ], [ overlap.rule, overlap.other ]
    assert_equal [ 1, 2 ], [ overlap.shared_count, overlap.match_count ]
    assert_equal [ :category_id ], overlap.attributes
    assert_empty health.shadowed
  end

  test "rules that set different fields on shared transactions do not overlap" do
    create_rule(name_condition("like", "woolworths"), category: @groceries)
    create_rule(
      Rule::Condition.new(condition_type: "compound", operator: "or", sub_conditions: [ name_condition("like", "metro"), name_condition("like", "hardware") ]),
      tags: [ @tag ]
    )

    assert_empty health.overlaps
  end

  test "rules whose text is the same or contained overlap even without shared transactions" do
    above = create_rule(name_condition("like", "uber"), category: @groceries)
    below = create_rule(name_condition("=", "UBER EATS"), category: @dining)

    overlap = health.overlaps.sole
    assert_equal [ below, above ], [ overlap.rule, overlap.other ]
    assert overlap.same_text
    assert_equal 0, overlap.shared_count
  end

  test "a merchant condition is compared by the merchant's name" do
    merchant = @family.merchants.create!(name: "Uber Eats")
    above = create_rule(Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: merchant.id), category: @groceries)
    below = create_rule(name_condition("like", "uber"), category: @dining)

    assert_equal [ [ below, above ] ], health.overlaps.map { |overlap| [ overlap.rule, overlap.other ] }

    merchant.update!(name: "Deliveroo")

    assert_empty health.overlaps
  end

  test "rules with contained text that set different fields do not overlap" do
    create_rule(name_condition("like", "uber"), category: @groceries)
    create_rule(name_condition("=", "UBER EATS"), tags: [ @tag ])

    assert_empty health.overlaps
  end

  test "lists the rules that match nothing today" do
    nothing = create_rule(name_condition("like", "no such shop"), category: @groceries)
    create_rule(name_condition("like", "woolworths"), category: @groceries)

    assert_equal [ nothing ], health.match_nothing
  end

  test "a rule whose pattern times out is reported as failed and the rest of the report still returns" do
    timing_out = create_rule(name_condition("matches_regex", "^Wool"), category: @groceries)
    nothing = create_rule(name_condition("like", "no such shop"), category: @groceries)
    Rule::SafeRegex.stubs(:with_timeout).raises(Rule::SafeRegex::TimeoutError)

    report = health
    assert_equal [ timing_out ], report.failed
    assert_equal [ nothing ], report.match_nothing
  end

  test "a rule whose query fails is reported as failed and the rules after it are still checked" do
    broken = create_rule(Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @family.merchants.create!(name: "Shop").id), category: @groceries)
    broken.conditions.first.update_columns(value: "not-a-uuid")
    nothing = create_rule(name_condition("like", "no such shop"), category: @groceries)

    report = health
    assert_equal [ broken ], report.failed
    assert_equal [ nothing ], report.match_nothing
  end

  test "a rule below with the same conditions that sets the same value and does more is an overlap" do
    above = create_rule(name_condition("like", "woolworths"), category: @groceries)
    below = create_rule(name_condition("like", "woolworths"), category: @groceries, tags: [ @tag ])

    report = health
    assert_empty report.duplicates
    assert_empty report.conflicts
    assert_equal [ [ below, above, 2 ] ], report.overlaps.map { |overlap| [ overlap.rule, overlap.other, overlap.shared_count ] }
  end

  test "a rule with an action that cannot be resolved is not reported as shadowed" do
    create_rule(name_condition("like", "woolworths"), category: @groceries)
    broken = create_rule(name_condition("like", "metro"), category: @dining)
    broken.actions.first.update_column(:action_type, "unknown_action")

    assert_empty health.shadowed
  end

  test "the shadowed rules are those a real run leaves unchanged although they match" do
    create_rule(name_condition("like", "woolworths"), category: @groceries)
    create_rule(name_condition("like", "metro"), category: @dining)
    create_rule(name_condition("like", "eats"), category: @dining)
    create_rule(name_condition("like", "uber"), category: @groceries)
    create_rule(name_condition("like", "store"), tags: [ @tag ])
    create_rule(name_condition("like", "o"), category: @dining)

    shadowed = health.shadowed.map(&:rule).to_set
    runs = Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "manual").run
    unchanged = runs.select { |run| run.transactions_queued.positive? && run.transactions_modified.zero? }.map(&:rule).to_set

    assert_equal 2, shadowed.size
    assert_equal unchanged, shadowed
  end

  test "compares an unsaved rule with compound conditions against the family's active and inactive rules" do
    active = create_rule(name_condition("like", "woolworths"), amount_condition, category: @groceries)
    inactive = create_rule(name_condition("like", "woolworths"), amount_condition, category: @dining, active: false)
    create_rule(name_condition("like", "hardware"), category: @groceries)
    rule = @family.rules.build(resource_type: "transaction")
    rule.conditions.build(condition_type: "compound", operator: "and", sub_conditions: [ amount_condition, name_condition("like", " WOOLWORTHS") ])
    rule.actions.build(action_type: "set_transaction_category", value: @groceries.id)

    similar = health.similar_to(rule)

    assert_equal [ active, inactive ], similar.map(&:rule)
    assert_equal [ true, nil ], similar.map(&:wins)
    assert_equal [ 2, nil ], similar.map(&:shared_count)
  end

  test "a rule whose matches cannot be read gets no shared count rather than zero" do
    existing = create_rule(name_condition("like", "woolworths"), category: @groceries)
    rule = @family.rules.build(resource_type: "transaction")
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "woolworths metro")
    rule.conditions.build(condition_type: "transaction_merchant", operator: "=", value: "not-a-uuid")
    rule.actions.build(action_type: "set_transaction_category", value: @dining.id)

    similar = health.similar_to(rule).sole

    assert_equal existing, similar.rule
    assert_nil similar.shared_count
  end

  test "a condition marked for destruction on an edited rule is left out" do
    existing = create_rule(name_condition("like", "woolworths"), category: @groceries)
    edited = create_rule(name_condition("like", "woolworths"), name_condition("like", "hardware"), category: @groceries)
    edited.reload.conditions.find { |condition| condition.value == "hardware" }.mark_for_destruction

    similar = health.similar_to(edited)

    assert_equal [ existing ], similar.map(&:rule)
    assert_equal [ 2 ], similar.map(&:shared_count)
  end

  private
    def health
      Rule::Health.new(@family)
    end

    def create_rule(*conditions, category: nil, tags: nil, active: true, stop_processing: false, effective_date: nil)
      actions = []
      actions << Rule::Action.new(action_type: "set_transaction_category", value: category.id) if category
      actions << Rule::Action.new(action_type: "set_transaction_tags", value: tags.map(&:id)) if tags
      @family.rules.create!(resource_type: "transaction", active: active, stop_processing: stop_processing,
        effective_date: effective_date, conditions: conditions, actions: actions)
    end

    def name_condition(operator, value)
      Rule::Condition.new(condition_type: "transaction_name", operator: operator, value: value)
    end

    def amount_condition
      Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: "10")
    end
end
