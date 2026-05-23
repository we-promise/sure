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
end
