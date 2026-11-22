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

  test "a stop rule and a rule that does not stop are not duplicates" do
    create_rule(name_condition("like", "woolworths"), category: @groceries, stop_processing: true)
    create_rule(name_condition("like", "woolworths"), category: @groceries)

    assert_empty health.duplicates
  end

  test "an additional detail condition keeps its key's case and folds only a contains value" do
    upper = create_rule(detail_condition("like", "MCC=ABC"), category: @groceries)
    lower = create_rule(detail_condition("like", "MCC=abc"), category: @dining)
    create_rule(detail_condition("like", "mcc=abc"), category: @groceries)

    assert_equal [ [ upper, lower ] ], health.conflicts.map(&:rules)
  end

  test "an additional detail value keeps its inner spacing" do
    double = create_rule(detail_condition("=", "reference=A  B"), category: @groceries)
    create_rule(detail_condition("=", " reference = A B "), category: @dining)
    padded = create_rule(detail_condition("=", "reference = A  B "), category: @dining)

    report = health
    assert_equal [ [ double, padded ] ], report.conflicts.map(&:rules)
    assert_empty report.duplicates
  end

  test "a transaction details value is compared as typed, apart from the case of a contains value" do
    create_rule(details_condition("like", "Ref  A"), category: @groceries)
    create_rule(details_condition("like", "Ref A "), category: @dining)
    folded = create_rule(details_condition("like", "ref a"), category: @groceries)
    upper = create_rule(details_condition("like", "REF A"), category: @dining)

    assert_equal [ [ folded, upper ] ], health.conflicts.map(&:rules)
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

  test "a rule whose field is claimed counts only the matches no rule above stopped" do
    create_rule(name_condition("like", "metro"), tags: [ @tag ], stop_processing: true)
    above = create_rule(name_condition("like", "hardware"), category: @groceries)
    below = create_rule(
      Rule::Condition.new(condition_type: "compound", operator: "or", sub_conditions: [ name_condition("like", "metro"), name_condition("like", "hardware") ]),
      category: @dining
    )

    entry = health.shadowed.sole
    assert_equal [ below, :claimed, [ above ] ], [ entry.rule, entry.reason, entry.by ]
    assert_equal 2, health.match_count(below)
    assert_equal 1, entry.match_count
  end

  test "a rule that only adds tags is not shadowed, since tags claim nothing" do
    create_rule(name_condition("like", "woolworths"), category: @groceries)
    create_rule(name_condition("like", "metro"), tags: [ @tag ])

    assert_empty health.shadowed
  end

  test "a rule whose conditions read a field a rule above changes gets no shadowed or match-nothing verdict" do
    create_transaction(account: @account, name: "Uber ride", amount: 77)
    rename = create_rule(name_condition("like", "uber ride"), name: "Taxi")
    create_rule(name_condition("like", "uber ride"), category: @groceries)
    by_amount = create_rule(amount_condition("=", "77"), category: @dining)
    taxi = create_rule(name_condition("like", "taxi"), category: @groceries)

    report = health
    assert_empty report.shadowed
    assert_empty report.match_nothing

    rename.update!(active: false)

    report = health
    assert_equal [ by_amount ], report.shadowed.map(&:rule)
    assert_equal [ taxi ], report.match_nothing
  end

  test "a rule that may match more after a rename is not reported as shadowed" do
    create_transaction(account: @account, name: "Uber ride", amount: 77)
    rename = create_rule(name_condition("like", "hardware"), name: "Uber ride two")
    create_rule(amount_condition("=", "77"), category: @groceries)
    by_name = create_rule(name_condition("like", "uber ride"), category: @dining)

    assert_empty health.shadowed

    rename.update!(active: false)

    assert_equal [ by_name ], health.shadowed.map(&:rule)
  end

  test "a rule that may match more after a rename passes the doubt to the rules reading what it sets" do
    create_transaction(account: @account, name: "Uber ride", amount: 77)
    rename = create_rule(name_condition("like", "uber ride"), name: "Taxi")
    taxi = create_rule(name_condition("like", "taxi"), category: @groceries)
    by_category = create_rule(select_condition("transaction_category", @groceries.id), tags: [ @tag ])
    by_tag = create_rule(select_condition("transaction_tag", @tag.id), category: @dining)

    assert_empty health.match_nothing

    rename.update!(active: false)

    assert_equal [ taxi, by_category, by_tag ], health.match_nothing
  end

  test "a rule above that matches nothing leaves the verdicts below it standing" do
    create_rule(name_condition("like", "no such shop"), category: @groceries)
    below = create_rule(select_condition("transaction_category", @groceries.id), tags: [ @tag ])

    assert_includes health.match_nothing, below
  end

  test "the verdicts left after a rename agree with a real run" do
    create_transaction(account: @account, name: "Uber ride", amount: 77)
    create_rule(name_condition("like", "uber ride"), name: "Taxi")
    create_rule(name_condition("like", "uber ride"), category: @groceries)
    create_rule(amount_condition("=", "77"), category: @dining)
    create_rule(name_condition("like", "taxi"), tags: [ @tag ])

    report = health
    shadowed = report.shadowed.map(&:rule)
    nothing = report.match_nothing

    runs = Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "manual").run
    unchanged = runs.select { |run| run.transactions_queued.positive? && run.transactions_modified.zero? }.map(&:rule)
    matched_nothing = runs.select { |run| run.transactions_queued.zero? }.map(&:rule)

    assert_empty shadowed - unchanged
    assert_empty nothing - matched_nothing
  end

  test "a rule below a transfer action that reads the new counterparts is not listed as matching nothing" do
    savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)
    create_rule(name_condition("like", "hardware"), transfer_to: savings)
    on_savings = create_rule(select_condition("transaction_account", savings.id), category: @dining)

    assert_not_includes health.match_nothing, on_savings

    runs = Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "manual").run
    assert runs.find { |run| run.rule == on_savings }.transactions_queued.positive?
  end

  test "a transfer rule that matches nothing leaves the verdicts below it standing" do
    savings = @family.accounts.create!(name: "Savings", balance: 0, currency: "USD", accountable: Depository.new)
    create_rule(name_condition("like", "no such shop"), transfer_to: savings)
    on_savings = create_rule(select_condition("transaction_account", savings.id), category: @dining)

    assert_includes health.match_nothing, on_savings
  end

  test "a rule below a split that reads the new children is not listed as matching nothing" do
    create_rule(name_condition("like", "hardware"), split_into: [ "Materials", "Labour" ])
    on_labour = create_rule(name_condition("like", "labour"), category: @dining)

    assert_not_includes health.match_nothing, on_labour

    runs = Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "manual").run
    assert runs.find { |run| run.rule == on_labour }.transactions_queued.positive?
  end

  test "a split rule that matches nothing leaves the verdicts below it standing" do
    create_rule(name_condition("like", "no such shop"), split_into: [ "Materials", "Labour" ])
    on_labour = create_rule(name_condition("like", "labour"), category: @dining)

    assert_includes health.match_nothing, on_labour
  end

  test "an inactive rule that matches nothing is not listed" do
    create_rule(name_condition("like", "no such shop"), category: @groceries, active: false)
    active = create_rule(name_condition("like", "no such place"), category: @groceries)

    assert_equal [ active ], health.match_nothing
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

  private
    def health
      Rule::Health.new(@family)
    end

    def create_rule(*conditions, category: nil, tags: nil, name: nil, transfer_to: nil, split_into: nil, active: true, stop_processing: false, effective_date: nil)
      actions = []
      actions << Rule::Action.new(action_type: "set_transaction_name", value: name) if name
      actions << Rule::Action.new(action_type: "set_transaction_category", value: category.id) if category
      actions << Rule::Action.new(action_type: "set_transaction_tags", value: tags.map(&:id)) if tags
      actions << Rule::Action.new(action_type: "set_as_transfer_or_payment", value: transfer_to.id) if transfer_to
      if split_into
        splits = split_into.map { |split_name| { type: "percentage", name: split_name, share: (100.0 / split_into.size).to_s } }
        actions << Rule::Action.new(action_type: "split_transaction", value: { splits: splits }.to_json)
      end
      @family.rules.create!(resource_type: "transaction", active: active, stop_processing: stop_processing,
        effective_date: effective_date, conditions: conditions, actions: actions)
    end

    def name_condition(operator, value)
      Rule::Condition.new(condition_type: "transaction_name", operator: operator, value: value)
    end

    def select_condition(condition_type, value)
      Rule::Condition.new(condition_type: condition_type, operator: "=", value: value)
    end

    def detail_condition(operator, value)
      Rule::Condition.new(condition_type: "transaction_additional_detail", operator: operator, value: value)
    end

    def details_condition(operator, value)
      Rule::Condition.new(condition_type: "transaction_details", operator: operator, value: value)
    end

    def amount_condition(operator = ">", value = "10")
      Rule::Condition.new(condition_type: "transaction_amount", operator: operator, value: value)
    end
end
