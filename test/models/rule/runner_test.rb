require "test_helper"

class Rule::RunnerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper, ActiveJob::TestHelper

  setup do
    use_ai_routes
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
    Rule::Layout.new(@family).reorder!([ "rule:#{bottom.id}", "rule:#{top.id}" ])

    run_active_rules

    assert_equal @dining, @whole_foods.reload.category
  end

  test "rules in a group run where the group stands in the list" do
    create_rule("Loose", "Whole Foods", category: @groceries)
    grouped = create_rule("Grouped", "Whole Foods", category: @dining)
    group = @family.rule_groups.create!(name: "Dining")
    grouped.update!(rule_group: group)

    run_active_rules
    assert_equal @groceries, @whole_foods.reload.category

    @whole_foods.update!(category: nil)
    loose_key = "rule:#{@family.rules.find_by!(name: "Loose").id}"
    Rule::Layout.new(@family).reorder!([ "group:#{group.id}", loose_key ])

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

  test "a rule above whose category was deleted does not claim the field" do
    deleted = @family.categories.create!(name: "Deleted")
    create_rule("Top", "Whole Foods", category: deleted)
    create_rule("Bottom", "Whole Foods", category: @dining)
    deleted.destroy!

    run_active_rules

    assert_equal @dining, @whole_foods.reload.category
  end

  test "a rule above with a blank name does not claim the name" do
    top = create_rule("Top", "Whole Foods", name: "Placeholder")
    top.actions.first.update_column(:value, "")
    create_rule("Bottom", "Whole", name: "Whole Foods")

    run_active_rules

    assert_equal "Whole Foods", @whole_foods.reload.entry.name
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

  test "applying a single rule runs the active rules above it first" do
    top = create_rule("Top", "Whole Foods", category: @groceries)
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    runs = Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    # Same as the full run: the top rule sets the category and wins
    assert_equal @groceries, @whole_foods.reload.category
    assert_equal [ top, bottom ], runs.map(&:rule)
  end

  test "applying a single rule does not run the rules below it" do
    top = create_rule("Top", "Whole Foods", category: @groceries)
    create_rule("Bottom", "Hardware", category: @dining)

    Rule::Runner.new(@family, rules: [ top ], execution_type: "manual").run

    assert_equal @groceries, @whole_foods.reload.category
    assert_nil @other.reload.category
  end

  test "ignoring locks only applies to the applied rule, not the rules above" do
    @whole_foods.entry.lock_attr!(:name)
    create_rule("Top", "Whole Foods", name: "Renamed")
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual", ignore_attribute_locks: true).run

    @whole_foods.reload
    assert_equal "Whole Foods Market", @whole_foods.entry.name
    assert_equal @dining, @whole_foods.category
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

  test "every action of a rule works on the transactions it matched" do
    @family.rules.create!(
      name: "Rename and categorize",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      # The rename runs first and changes the name the condition reads
      actions: [
        Rule::Action.new(action_type: "set_transaction_name", value: "Groceries store"),
        Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id)
      ]
    )
    create_rule("Catch-all", "o", category: @dining)

    run_active_rules

    @whole_foods.reload
    assert_equal "Groceries store", @whole_foods.entry.name
    assert_equal @groceries, @whole_foods.category
    assert_equal @dining, @other.reload.category
  end

  test "a rule counts a transaction once when several actions change it" do
    rule = create_rule("Tag and categorize", "Whole Foods", category: @groceries, tags: [ @tag_a ])

    rule_run = Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run.first

    assert_equal 1, rule_run.transactions_queued
    assert_equal 1, rule_run.transactions_processed
    assert_equal 1, rule_run.transactions_modified
    assert_equal 0, rule_run.transactions_blocked

    @whole_foods.reload
    assert_equal @groceries, @whole_foods.category
    assert_equal [ @tag_a.id ], @whole_foods.tag_ids
  end

  test "a rule counts a transaction once when an AI action changes one its other action changed" do
    rule = @family.rules.create!(
      name: "Tag and categorize with AI",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "o") ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_tags", value: [ @tag_a.id ]),
        Rule::Action.new(action_type: "auto_categorize")
      ]
    )
    # Already tagged, so the tag action only changes @other and the AI is the
    # only action that changes this transaction.
    @whole_foods.update!(tag_ids: [ @tag_a.id ])

    llm_provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(llm_provider)
    llm_provider.expects(:auto_categorize).returns(provider_success_response([
      Provider::LlmConcept::AutoCategorization.new(transaction_id: @whole_foods.id, category_name: @groceries.name),
      Provider::LlmConcept::AutoCategorization.new(transaction_id: @other.id, category_name: @dining.name)
    ])).once

    runner = Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual")
    perform_enqueued_jobs(only: AutoCategorizeJob) { runner.run }

    rule_run = rule.rule_runs.sole.reload

    assert_equal 2, rule_run.transactions_processed
    # @other changed by the tag action and the AI, @whole_foods only by the AI.
    assert_equal 2, rule_run.transactions_modified
    assert_equal @groceries, @whole_foods.reload.category
    assert_equal @dining, @other.reload.category
  end

  test "a rule whose only action is AI leaves the modified count to its jobs" do
    rule = @family.rules.create!(
      name: "Categorize with AI",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "o") ],
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )

    assert_enqueued_jobs 1, only: AutoCategorizeJob do
      Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run
    end

    rule_run = rule.rule_runs.sole.reload

    assert_equal 2, rule_run.transactions_processed
    assert_equal 0, rule_run.transactions_modified
    assert_equal 1, rule_run.pending_jobs_count
    assert_equal 0, rule_run.transactions_blocked
  end

  test "records the pending job count before it enqueues an AI job" do
    rule = @family.rules.create!(
      name: "Categorize with AI",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "o") ],
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    pending_when_enqueued = nil

    Family.any_instance.stubs(:auto_categorize_transactions_later).with do |_transactions, **_options|
      pending_when_enqueued = rule.rule_runs.sole.pending_jobs_count
      true
    end

    Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run

    assert_equal 1, pending_when_enqueued
    assert_equal 1, rule.rule_runs.sole.reload.pending_jobs_count
  end

  test "does not wait for jobs that never enqueued when an AI enqueue fails" do
    rule = @family.rules.create!(
      name: "Categorize with AI",
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "o") ],
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )

    Provider::LlmConcept.stubs(:max_items_per_call).returns(1)
    calls = 0
    Family.any_instance.stubs(:auto_categorize_transactions_later).with do |_transactions, **_options|
      calls += 1
      raise "queue unavailable" if calls == 2
      true
    end

    rule_run = Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run.sole.reload

    assert_equal 2, calls
    assert_equal "failed", rule_run.status
    # The first batch was enqueued; the second and the jobs after it were not.
    assert_equal 1, rule_run.pending_jobs_count
  end

  test "applying a single rule sees the changes the rules above make" do
    create_rule("Rename", "Whole Foods", name: "Supermarket")
    middle = create_rule("Middle", "Supermarket", category: @groceries)
    create_rule("Catch-all", "o", category: @dining)

    Rule::Runner.new(@family, rules: [ middle ], execution_type: "manual").run

    @whole_foods.reload
    single_result = [ @whole_foods.entry.name, @whole_foods.category ]
    assert_equal [ "Supermarket", @groceries ], single_result
    # The catch-all below the applied rule did not run
    assert_nil @other.reload.category

    run_active_rules

    @whole_foods.reload
    assert_equal single_result, [ @whole_foods.entry.name, @whole_foods.category ]
    assert_equal @dining, @other.reload.category
  end

  test "a rule with a broken action does not stop the rules below" do
    broken = create_rule("Broken", "Whole Foods", category: @groceries)
    broken.actions.first.update_column(:action_type, "unknown_action")
    create_rule("Bottom", "Whole Foods", category: @dining)

    runner = Rule::Runner.new(@family, rules: @family.rules, execution_type: "manual")
    runs = runner.run

    assert_equal [ "failed", "success" ], runs.map(&:status)
    assert_equal @dining, @whole_foods.reload.category
  end

  test "a broken action above an applied rule does not stop it" do
    broken = create_rule("Broken", "Whole Foods", category: @groceries)
    broken.actions.first.update_column(:action_type, "unknown_action")
    bottom = create_rule("Bottom", "Whole Foods", category: @dining)

    Rule::Runner.new(@family, rules: [ bottom ], execution_type: "manual").run

    assert_equal @dining, @whole_foods.reload.category
  end

  test "a split rule higher up keeps the categories it gives the children" do
    split = { splits: [
      { type: "percentage", name: "Whole Foods groceries", share: "50", category_id: @groceries.id },
      { type: "percentage", name: "Whole Foods other", share: "50" }
    ] }
    @family.rules.create!(
      name: "Split", resource_type: "transaction", active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "split_transaction", value: split.to_json) ]
    )
    create_rule("Bottom", "Whole Foods", category: @dining)

    run_active_rules

    children = @whole_foods.entry.reload.child_entries.index_by(&:name)
    assert_equal @groceries, children["Whole Foods groceries"].transaction.category
    # The split set no category here, so the rule below still may.
    assert_equal @dining, children["Whole Foods other"].transaction.category
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
