require "test_helper"

class ApplyAllRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "applies all rules for a family" do
    # Create a rule
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Mock RuleJob to verify it gets called for each rule
    RuleJob.expects(:perform_now).with(rule, ignore_attribute_locks: true, execution_type: "manual").once

    ApplyAllRulesJob.perform_now(@family)
  end

  test "applies all rules with custom execution type" do
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Test") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    RuleJob.expects(:perform_now).with(rule, ignore_attribute_locks: true, execution_type: "scheduled").once

    ApplyAllRulesJob.perform_now(@family, execution_type: "scheduled")
  end
end
