require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::DownstreamTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  include ActiveJob::TestHelper
  setup do
    financekit_setup
    @batch = FinancekitBatch.accept!(@item, financekit_envelope)
    assert Financekit::Processor.new(@item).apply_next!
    @batch.reload
  end

  test "a sync started before import cannot acknowledge recalculation" do
    @source.account.syncs.create!(status: "completed", created_at: 1.minute.ago, completed_at: Time.current)
    assert_difference "Sync.count", 1 do
      Financekit::Downstream.new(@batch).perform!
    end
    assert_nil @batch.reload.downstream_completed_at
  end

  test "lost sync jobs are rescheduled without another device request" do
    Financekit::Downstream.new(@batch).perform!
    first_sync = @source.account.syncs.sole
    travel 6.minutes
    assert_difference "Sync.count", 1 do
      Financekit::Downstream.new(@batch).perform!
    end
    assert_not_equal first_sync.id, @source.account.syncs.ordered.first.id
    assert_nil @batch.reload.downstream_completed_at
  end

  test "rule enqueue and pending enrichment cannot acknowledge downstream completion" do
    @source.account.syncs.create!(status: "completed", completed_at: Time.current)
    rule = rules(:one)
    rule.update_columns(family_id: @family.id, active: true)
    assert_enqueued_with(job: RuleJob) { Financekit::Downstream.new(@batch).perform! }
    assert_nil @batch.reload.downstream_completed_at
    run = rule.rule_runs.create!(status: "pending", execution_type: "scheduled", executed_at: Time.current)
    travel 6.minutes
    assert_enqueued_with(job: RuleJob) { Financekit::Downstream.new(@batch).perform! }
    assert_nil @batch.reload.downstream_completed_at
    run.update!(status: "success")
    travel 6.minutes
    Financekit::Downstream.new(@batch).perform!
    assert_not_nil @batch.reload.downstream_completed_at
  end

  test "a downstream outage leaves the outbox recoverable" do
    Financekit::Downstream.any_instance.stubs(:perform!).raises(StandardError, "sensitive payload")
    assert_nothing_raised { FinancekitInboxJob.perform_now }
    assert_nil @batch.reload.downstream_completed_at
    assert_equal "applied", @batch.status
    assert_not_includes DebugLogEntry.order(:created_at).last.message, "sensitive payload"
  end
end
