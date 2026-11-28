require "test_helper"

class ApplyRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @transaction = create_transaction(account: @account, name: "Whole Foods").transaction
  end

  test "applies only active rules and records scheduled runs" do
    active_rule = create_rule(active: true)
    inactive_rule = create_rule(active: false)

    ApplyRulesJob.perform_now(@family)

    assert_equal @groceries, @transaction.reload.category
    assert_equal [ "scheduled" ], active_rule.rule_runs.pluck(:execution_type)
    assert_empty inactive_rule.rule_runs
  end

  test "respects locked fields" do
    create_rule(active: true)
    @transaction.lock_attr!(:category_id)

    ApplyRulesJob.perform_now(@family)

    assert_nil @transaction.reload.category
  end

  test "retries later when another rule run holds the family lock" do
    create_rule(active: true)
    Rule::Runner.any_instance.stubs(:run).raises(Rule::Runner::LockBusy)

    assert_enqueued_with(job: ApplyRulesJob) do
      ApplyRulesJob.perform_now(@family)
    end
  end

  test "after a sync, warms Reports once the rules have run" do
    create_rule(active: true)

    assert_enqueued_with(job: WarmReportsCacheJob, args: [ @family ]) do
      ApplyRulesJob.perform_now(@family, warm_reports: true)
    end
    assert_equal @groceries, @transaction.reload.category

    assert_no_enqueued_jobs(only: WarmReportsCacheJob) { ApplyRulesJob.perform_now(@family) }
  end

  test "a rule run that must retry warms Reports only when it finishes" do
    Rule::Runner.any_instance.stubs(:run).raises(Rule::Runner::LockBusy)

    assert_no_enqueued_jobs(only: WarmReportsCacheJob) do
      ApplyRulesJob.perform_now(@family, warm_reports: true)
    end
    assert_enqueued_with(job: ApplyRulesJob, args: [ @family, { warm_reports: true } ])
  end

  private
    def create_rule(active:)
      @family.rules.create!(
        resource_type: "transaction",
        active: active,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries.id) ]
      )
    end
end
