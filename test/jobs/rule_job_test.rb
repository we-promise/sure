require "test_helper"

class RuleJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule job test", balance: 1000, currency: "USD", accountable: Depository.new)
    @food_and_dining = @family.categories.create!(name: "Food & Dining")
    @groceries = @family.categories.create!(name: "Groceries")
  end

  test "records manually locked matching transactions as blocked" do
    20.times do |index|
      create_transaction(
        account: @account,
        name: "Whole Foods #{index}",
        date: Date.current - index.days
      )
    end

    manually_locked_transactions = @family.transactions
                                            .joins(:entry)
                                            .where("entries.name LIKE ?", "Whole Foods%")
                                            .order("entries.date DESC")
                                            .limit(10)

    manually_locked_transactions.each do |transaction|
      transaction.update!(category: @groceries)
      transaction.lock_attr!(:category_id)
      transaction.entry.mark_user_modified!
    end

    rule = @family.rules.create!(
      name: "Whole Foods Testing",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: @food_and_dining.id)
      ]
    )

    RuleJob.perform_now(rule)

    rule_run = rule.rule_runs.order(:created_at).last
    assert_equal 20, rule_run.transactions_queued
    assert_equal 20, rule_run.transactions_processed
    assert_equal 10, rule_run.transactions_modified
    assert_equal 10, rule_run.transactions_blocked
  end

  test "captures a debug log entry when the rule run raises" do
    rule = @family.rules.create!(
      name: "Failing rule",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods")
      ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: @food_and_dining.id)
      ]
    )

    error = RuntimeError.new("boom")
    Rule.any_instance.stubs(:apply).raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      assert_raises(RuntimeError) { RuleJob.perform_now(rule) }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "Rule::Runner", entry.source
    assert_equal @family, entry.family
    assert_equal rule.id, entry.metadata["rule_id"]
    assert_equal "RuntimeError", entry.metadata["error_class"]

    rule_run = rule.rule_runs.order(:created_at).last
    assert_equal "failed", rule_run.status
  end

  test "a failing rule above is recorded but does not fail the job" do
    create_transaction(account: @account, name: "Whole Foods")
    above = @family.rules.create!(
      name: "Above", resource_type: "transaction", active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id) ]
    )
    above.actions.first.update_column(:action_type, "unknown_action")
    rule = @family.rules.create!(
      name: "Applied", resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @food_and_dining.id) ]
    )

    assert_nothing_raised { RuleJob.perform_now(rule) }

    assert_equal "failed", above.rule_runs.last.status
    assert_equal "success", rule.rule_runs.last.status
  end

  test "fails the job when the applied rule fails" do
    rule = @family.rules.create!(
      name: "Applied", resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @food_and_dining.id) ]
    )
    rule.actions.first.update_column(:action_type, "unknown_action")

    assert_raises(Rule::Registry::UnsupportedActionError) { RuleJob.perform_now(rule) }
  end

  test "an AI job that can't be queued fails the run, not the job" do
    create_transaction(account: @account, name: "Whole Foods")
    rule = @family.rules.create!(
      name: "AI", resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    Family.any_instance.stubs(:auto_categorize_transactions_later).returns(false)

    assert_nothing_raised { RuleJob.perform_now(rule, user_id: users(:empty).id) }

    rule_run = rule.rule_runs.sole
    assert_equal "failed", rule_run.status
    assert_match "ActiveJob::EnqueueError", rule_run.error_message
  end

  test "still runs when the member who applied the rule is deleted while it waits" do
    transaction = create_transaction(account: @account, name: "Whole Foods").transaction
    rule = @family.rules.create!(
      name: "Applied", resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @food_and_dining.id) ]
    )
    member = @family.users.create!(email: "leaving-rule@example.com", password: "password123", role: :member)
    rule.apply_later(user: member)
    member.destroy!

    perform_enqueued_jobs

    assert_equal @food_and_dining, transaction.reload.category
  end
end
