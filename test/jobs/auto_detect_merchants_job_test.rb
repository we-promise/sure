require "test_helper"

class AutoDetectMerchantsJobTest < ActiveJob::TestCase
  include ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @transaction = transactions(:one)
    @rule_run = rules(:one).rule_runs.create!(
      rule_name: rules(:one).name,
      execution_type: "manual",
      status: "pending",
      transactions_queued: 1,
      transactions_processed: 0,
      transactions_modified: 0,
      pending_jobs_count: 1,
      executed_at: Time.current
    )
  end

  test "records the failure of a batch that can't succeed and ends it" do
    Family.any_instance.stubs(:auto_detect_transaction_merchants).raises(StandardError, "Invalid JSON in provider response")

    assert_difference "DebugLogEntry.count", 1 do
      perform_enqueued_jobs do
        AutoDetectMerchantsJob.perform_later(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
      end
    end

    assert_no_enqueued_jobs

    @rule_run.reload

    assert_equal "failed", @rule_run.status
    assert_equal 0, @rule_run.pending_jobs_count
    assert_equal "StandardError: Invalid JSON in provider response", @rule_run.error_message

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "AutoDetectMerchantsJob", entry.source
    assert_equal @family, entry.family
    assert_equal @rule_run.id, entry.metadata["rule_run_id"]
    assert_equal [ @transaction.id ], entry.metadata["transaction_ids"]
  end

  test "a provider timeout is retried instead of passing as a success" do
    provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    timeout = Provider::Openai.new("test-token").send(:default_error_transformer, Faraday::TimeoutError.new("execution expired"))
    provider.expects(:auto_detect_merchants).times(RuleAiJob::ATTEMPTS).returns(provider_error_response(timeout))

    perform_enqueued_jobs do
      AutoDetectMerchantsJob.perform_later(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
    end

    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_match "Ai::Error::Timeout", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count
  end
end
