require "test_helper"

class BayesCategorizeJobTest < ActiveJob::TestCase
  setup do
    @family = families(:empty)
  end

  test "after a sync it runs Bayes, then queues the rules" do
    @family.expects(:bayes_categorize_uncategorized)

    assert_enqueued_with(job: ApplyRulesJob, args: [ @family ]) do
      BayesCategorizeJob.perform_now(@family, apply_rules: true)
    end
  end

  test "after a sync a failure is logged and the rules still run" do
    @family.stubs(:bayes_categorize_uncategorized).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.where(level: "error").count }, 1 do
      assert_enqueued_with(job: ApplyRulesJob, args: [ @family ]) do
        BayesCategorizeJob.perform_now(@family, apply_rules: true)
      end
    end
  end

  test "Run raises a failure and queues no rules" do
    @family.stubs(:bayes_categorize_uncategorized).raises(StandardError, "boom")

    assert_no_enqueued_jobs(only: ApplyRulesJob) do
      assert_raises(StandardError) { BayesCategorizeJob.perform_now(@family) }
    end
  end
end
