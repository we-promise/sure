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

  test "auto-categorize rule does not mark all transactions blocked when no categories are available" do
    3.times do |index|
      create_transaction(
        account: @account,
        name: "Uncategorized #{index}",
        date: Date.current - index.days
      )
    end

    @family.categories.destroy_all

    llm_provider = mock("llm_provider")
    llm_provider.expects(:auto_categorize).never
    Provider::Registry.stubs(:get_provider).with(:openai).returns(llm_provider)
    Provider::Registry.stubs(:preferred_llm_provider).returns(llm_provider)

    rule = @family.rules.create!(
      name: "Auto-categorize uncategorized",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Uncategorized")
      ],
      actions: [
        Rule::Action.new(action_type: "auto_categorize")
      ]
    )

    assert_enqueued_jobs 1, only: AutoCategorizeJob do
      RuleJob.perform_now(rule)
    end

    perform_enqueued_jobs only: AutoCategorizeJob

    rule_run = rule.rule_runs.order(:created_at).last

    assert_equal 3, rule_run.transactions_queued
    assert_equal 0, rule_run.transactions_processed
    assert_equal 0, rule_run.transactions_modified
    assert_equal 0, rule_run.transactions_blocked
  end
end
