require "test_helper"

class ApplyAllRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries_category = @family.categories.create!(name: "Groceries")
    @transaction = create_transaction(account: @account, name: "Whole Foods").transaction
  end

  test "applies all rules for a family, including inactive ones and locked fields" do
    rule = create_rule(active: false)
    @transaction.lock_attr!(:category_id)

    ApplyAllRulesJob.perform_now(@family)

    assert_equal @groceries_category, @transaction.reload.category
    assert_equal "manual", rule.rule_runs.last.execution_type
  end

  test "applies all rules with custom execution type" do
    rule = create_rule(active: true)

    ApplyAllRulesJob.perform_now(@family, execution_type: "scheduled")

    assert_equal "scheduled", rule.rule_runs.last.execution_type
  end

  private
    def create_rule(active:)
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: active,
        effective_date: 1.day.ago.to_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
      )
    end
end
