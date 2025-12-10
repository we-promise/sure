require "test_helper"

class RuleJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Transport")
  end

  test "applies rule when job receives id" do
    entry = create_transaction(account: @account, name: "Taxi ride", date: Date.current)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Taxi ride") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )

    perform_enqueued_jobs do
      RuleJob.perform_later(rule.id)
    end

    assert_equal @category, entry.reload.transaction.category
  end
end
