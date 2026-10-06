require "test_helper"

class Rule::RunnerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Runner test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
    @tag_a = @family.tags.create!(name: "Tag A")
    @tag_b = @family.tags.create!(name: "Tag B")

    @whole_foods = create_transaction(account: @account, name: "Whole Foods Market").transaction
    @other = create_transaction(account: @account, name: "Hardware store").transaction
  end

  test "the rule higher up wins when two rules set the same field" do
    create_rule("Top", "Whole Foods", category: @groceries)
    create_rule("Bottom", "Whole Foods", category: @dining)

    run_active_rules

    assert_equal @groceries, @whole_foods.reload.category
  end

  test "reordering changes which rule wins" do
    top = create_rule("Top", "Whole Foods", category: @groceries)
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)
    Rule.update_positions!(@family, [ bottom.id, top.id ])

    run_active_rules

    assert_equal @dining, @whole_foods.reload.category
  end

  test "a rule higher up claims the field even when it changes nothing" do
    @whole_foods.update!(category: @groceries)
    create_rule("Top", "Whole Foods", category: @groceries)
    create_rule("Bottom", "Whole Foods", category: @dining)

    run_active_rules

    assert_equal @groceries, @whole_foods.reload.category
  end

  test "rules further down still set fields the rules above leave alone" do
    create_rule("Top", "Whole Foods", category: @groceries)
    create_rule("Bottom", "Whole", name: "Whole Foods")

    run_active_rules

    @whole_foods.reload
    assert_equal @groceries, @whole_foods.category
    assert_equal "Whole Foods", @whole_foods.entry.name
  end

  test "stop processing keeps rules further down away from matched transactions" do
    create_rule("Top", "Whole Foods", category: @groceries, stop_processing: true)
    create_rule("Bottom", "o", name: "Renamed")

    run_active_rules

    assert_equal "Whole Foods Market", @whole_foods.reload.entry.name
    assert_equal "Renamed", @other.reload.entry.name
  end

  test "tags from several rules add up" do
    create_rule("Top", "Whole Foods", tags: [ @tag_a ])
    create_rule("Bottom", "Whole Foods", tags: [ @tag_b ])

    run_active_rules

    assert_equal [ @tag_a, @tag_b ].map(&:id).sort, @whole_foods.reload.tag_ids.sort
  end

  test "locked fields stay unchanged in the scheduled run" do
    @whole_foods.update!(category: @dining)
    @whole_foods.lock_attr!(:category_id)
    create_rule("Top", "Whole Foods", category: @groceries)

    run_active_rules

    assert_equal @dining, @whole_foods.reload.category
  end

  test "applying a single rule respects the rules above it" do
    create_rule("Top", "Whole Foods", category: @groceries)
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    # The top rule was only matched, not executed
    assert_nil @whole_foods.reload.category
    assert_equal 1, bottom.rule_runs.count
  end

  test "applying a single rule respects stop processing above it" do
    create_rule("Top", "Whole Foods", category: @groceries, stop_processing: true)
    bottom = create_rule("Bottom", "Whole Foods", name: "Renamed")

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    assert_equal "Whole Foods Market", @whole_foods.reload.entry.name
  end

  test "inactive rules above do not claim fields" do
    create_rule("Top", "Whole Foods", category: @groceries, active: false)
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    assert_equal @dining, @whole_foods.reload.category
  end

  test "an AI action above does not keep rules below from setting the field" do
    @family.rules.create!(
      name: "AI",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    assert_equal @dining, @whole_foods.reload.category
  end

  test "a rule above that cannot be matched does not stop the applied rule" do
    broken = create_rule("Broken", "Whole Foods", category: @groceries)
    broken.conditions.first.update!(condition_type: "transaction_notes")
    Rule::ConditionFilter::TransactionNotes.any_instance.stubs(:apply).raises(ActiveRecord::StatementInvalid, "bad condition")
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    assert_equal @dining, @whole_foods.reload.category
  end

  test "the effective date still limits which transactions a rule touches" do
    old = create_transaction(account: @account, name: "Whole Foods old", date: 2.years.ago.to_date).transaction
    create_rule("Top", "Whole Foods", category: @groceries, effective_date: 1.year.ago.to_date)

    run_active_rules

    assert_equal @groceries, @whole_foods.reload.category
    assert_nil old.reload.category
  end

  test "records a rule run per executed rule with the scheduled type" do
    top = create_rule("Top", "Whole Foods", category: @groceries, stop_processing: true)
    bottom = create_rule("Bottom", "o", name: "Renamed")

    runs = run_active_rules

    assert_equal [ top, bottom ], runs.map(&:rule)
    assert_equal %w[scheduled scheduled], runs.map(&:execution_type)
    # The bottom rule no longer sees the transaction the top rule stopped
    assert_equal 1, runs.last.transactions_queued
  end

  test "a failing rule is recorded and the remaining rules still run" do
    top = create_rule("Top", "Whole Foods", category: @groceries)
    create_rule("Bottom", "Hardware", name: "Renamed")
    Rule::ActionExecutor::SetTransactionCategory.any_instance.stubs(:execute).raises(StandardError, "boom")

    runner = Rule::Runner.new(@family, rules: @family.rules, execution_type: "manual")
    runs = runner.run

    assert_equal "failed", runs.first.status
    assert_equal top, runs.first.rule
    assert_equal "Renamed", @other.reload.entry.name
    assert_equal [ "boom" ], runner.errors.map(&:message)
  end

  test "raises LockBusy while another run holds the family lock" do
    create_rule("Top", "Whole Foods", category: @groceries)

    # Transactional tests share one PG session, and a session can re-take its
    # own advisory lock, so holding it needs a separate connection.
    config = ActiveRecord::Base.connection_pool.db_config.configuration_hash
    other = PG.connect({
      dbname: config[:database], host: config[:host], port: config[:port],
      user: config[:username] || config[:user], password: config[:password]
    }.compact)
    other.exec("SELECT pg_advisory_lock(#{Rule::Runner.advisory_lock_key(@family.id)})")

    assert_raises(Rule::Runner::LockBusy) { run_active_rules }
    assert_nil @whole_foods.reload.category
  ensure
    other&.close
  end

  private
    def run_active_rules
      Rule::Runner.new(@family, rules: @family.rules.where(active: true), execution_type: "scheduled").run
    end

    def create_rule(name, match, category: nil, tags: nil, stop_processing: false, active: true, effective_date: nil, **options)
      actions = []
      actions << Rule::Action.new(action_type: "set_transaction_category", value: category.id) if category
      actions << Rule::Action.new(action_type: "set_transaction_tags", value: tags.map(&:id)) if tags
      actions << Rule::Action.new(action_type: "set_transaction_name", value: options[:name]) if options[:name]

      @family.rules.create!(
        name: name,
        resource_type: "transaction",
        active: active,
        stop_processing: stop_processing,
        effective_date: effective_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: match) ],
        actions: actions
      )
    end
end
