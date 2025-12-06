require "test_helper"

class RuleScheduleWorkerTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    Sidekiq::Cron::Job.stubs(:create)
    Sidekiq::Cron::Job.stubs(:destroy)

    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 500, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Transport")

    @rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      schedule_enabled: true,
      schedule_cron: "0 0 * * *",
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Taxi") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @category.id) ]
    )
  end

  test "enqueues rule job on scheduled worker" do
    clear_enqueued_jobs

    assert_enqueued_with(job: RuleJob, queue: "scheduled") do
      RuleScheduleWorker.new.perform(@rule.id)
    end
  end

  test "skips when rule is inactive or scheduling disabled" do
    clear_enqueued_jobs

    @rule.update!(active: false)
    assert_no_enqueued_jobs do
      RuleScheduleWorker.new.perform(@rule.id)
    end

    @rule.update!(active: true, schedule_enabled: false)
    assert_no_enqueued_jobs do
      RuleScheduleWorker.new.perform(@rule.id)
    end
  end
end
