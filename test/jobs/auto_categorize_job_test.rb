require "test_helper"

class AutoCategorizeJobTest < ActiveJob::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @family.categories.create!(name: "Food")
    @rule = @family.rules.create!(
      name: "AI category rule",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "coffee")
      ],
      actions: [
        Rule::Action.new(action_type: "auto_categorize")
      ]
    )
    @rule_run = @rule.rule_runs.create!(
      rule_name: @rule.name,
      execution_type: "manual",
      status: "pending",
      transactions_queued: 20,
      transactions_processed: 20,
      transactions_modified: 0,
      pending_jobs_count: 1,
      executed_at: Time.current
    )
  end

  test "an unexpected error ends the run once instead of going through Sidekiq's retries" do
    error = RuntimeError.new("Fixed prompt tokens exceed context budget")
    transaction_ids = [ SecureRandom.uuid ]

    Family.any_instance.stubs(:auto_categorize_transactions).with(transaction_ids).raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      perform_enqueued_jobs do
        AutoCategorizeJob.perform_later(@family, transaction_ids: transaction_ids, rule_run_id: @rule_run.id)
      end
    end

    assert_no_enqueued_jobs
    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_equal "RuntimeError: Fixed prompt tokens exceed context budget", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "AutoCategorizeJob", entry.source
    assert_equal @family, entry.family
    assert_equal @rule_run.id, entry.metadata["rule_run_id"]
    assert_equal transaction_ids, entry.metadata["transaction_ids"]
  end

  test "records unsuccessful provider responses as rule run failures" do
    transaction = create_transaction(account: @account, name: "Coffee shop").transaction
    provider = mock
    provider_error = Provider::Error.new("Fixed prompt tokens exceed context budget")

    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.expects(:auto_categorize).once.returns(provider_error_response(provider_error))

    assert_difference "DebugLogEntry.count", 1 do
      perform_enqueued_jobs do
        AutoCategorizeJob.perform_later(@family, transaction_ids: [ transaction.id ], rule_run_id: @rule_run.id)
      end
    end

    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_equal "Family::AutoCategorizer::Error: Failed to auto-categorize transactions: Fixed prompt tokens exceed context budget", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "Family::AutoCategorizer::Error", entry.metadata["error_class"]
    assert_equal "Failed to auto-categorize transactions: Fixed prompt tokens exceed context budget", entry.metadata["error_message"]
    assert_equal [ transaction.id ], entry.metadata["transaction_ids"]
  end

  test "fails the rule run when no categories are available" do
    @family.categories.destroy_all
    transaction = create_transaction(account: @account, name: "Coffee shop").transaction
    provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.expects(:auto_categorize).never

    assert_difference "DebugLogEntry.count", 2 do
      perform_enqueued_jobs do
        AutoCategorizeJob.perform_later(@family, transaction_ids: [ transaction.id ], rule_run_id: @rule_run.id)
      end
    end

    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_equal "Family::AutoCategorizer::Error: No categories available for auto-categorization", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count

    entries = DebugLogEntry.order(:created_at).last(2)
    categorization_entry = entries.find { |entry| entry.category == "auto_categorization" }
    rule_run_entry = entries.find { |entry| entry.category == "rule_run" }

    assert_equal "AI categorization failed: no categories available", categorization_entry.message
    assert_equal [ transaction.id ], categorization_entry.metadata["requested_transaction_ids"]
    assert_equal "No categories available for auto-categorization", rule_run_entry.metadata["error_message"]
  end

  test "a key the provider rejects is discarded after one call, not retried" do
    transaction = create_transaction(account: @account, name: "Coffee shop").transaction
    openai_fails_with Faraday::UnauthorizedError.new("the server responded with status 401", { status: 401, body: "invalid_api_key" }), times: 1

    perform_enqueued_jobs do
      AutoCategorizeJob.perform_later(@family, transaction_ids: [ transaction.id ], rule_run_id: @rule_run.id)
    end

    assert_no_enqueued_jobs
    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_match "Ai::Error::Unauthorized", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count
  end

  test "a provider that stays down is retried a few times, then its batch is counted once" do
    @rule_run.update!(pending_jobs_count: 2)
    transaction = create_transaction(account: @account, name: "Coffee shop").transaction
    openai_fails_with Faraday::ServerError.new("the server responded with status 503", { status: 503, body: "overloaded" }), times: RuleAiJob::ATTEMPTS

    perform_enqueued_jobs do
      AutoCategorizeJob.perform_later(@family, transaction_ids: [ transaction.id ], rule_run_id: @rule_run.id)
    end

    assert_no_enqueued_jobs
    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_match "Ai::Error::Upstream", @rule_run.error_message
    assert_equal 1, @rule_run.pending_jobs_count, "the run's other batch is still running"
  end

  test "a provider that recovers on a retry completes the run without a failure" do
    transaction = create_transaction(account: @account, name: "Coffee shop").transaction
    provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    rate_limited = Provider::Openai.new("test-token").send(
      :default_error_transformer,
      Faraday::TooManyRequestsError.new("the server responded with status 429", { status: 429, body: "slow down" })
    )
    provider.expects(:auto_categorize).twice
      .returns(provider_error_response(rate_limited))
      .then.returns(provider_success_response([ categorization(transaction, "Food") ]))

    perform_enqueued_jobs do
      AutoCategorizeJob.perform_later(@family, transaction_ids: [ transaction.id ], rule_run_id: @rule_run.id)
    end

    @rule_run.reload
    assert_equal "success", @rule_run.status
    assert_nil @rule_run.error_message
    assert_equal 1, @rule_run.transactions_modified
    assert_equal "Food", transaction.reload.category.name
  end

  test "a job that runs again after its batch was counted doesn't count it twice" do
    @rule_run.update!(pending_jobs_count: 2)
    @family.stubs(:auto_categorize_transactions).raises(RuntimeError, "boom")
    job = AutoCategorizeJob.new(@family, transaction_ids: [ SecureRandom.uuid ], rule_run_id: @rule_run.id)

    2.times { job.perform_now }

    assert_equal 1, @rule_run.reload.pending_jobs_count
  end

  test "a retry after part of the batch was applied sends only what is left" do
    applied = create_transaction(account: @account, name: "Coffee shop").transaction
    left = create_transaction(account: @account, name: "Coffee beans").transaction
    provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    provider.expects(:auto_categorize).with { |args| sent_ids(args) == [ left.id ] }
      .once.returns(provider_success_response([ categorization(left, "Food") ]))
    provider.expects(:auto_categorize).with { |args| sent_ids(args) == [ applied.id, left.id ].sort }
      .once.returns(provider_success_response([ categorization(applied, "Food"), categorization(left, "Not a category") ]))
    # The batch is applied, then something transient fails before the job reports.
    DebugLogEntry.stubs(:capture).raises(ActiveRecord::Deadlocked).then.returns(nil)

    perform_enqueued_jobs do
      AutoCategorizeJob.perform_later(@family, transaction_ids: [ applied.id, left.id ], rule_run_id: @rule_run.id)
    end

    assert_equal "Food", applied.reload.category.name
    assert_equal "Food", left.reload.category.name
    @rule_run.reload
    assert_equal "success", @rule_run.status
    assert_equal 0, @rule_run.pending_jobs_count
  end

  private
    # Runs the real OpenAI provider, whose request fails with `error` each of `times`.
    def openai_fails_with(error, times:)
      Provider::Registry.stubs(:preferred_llm_provider).returns(Provider::Openai.new("test-token"))
      Provider::Openai::AutoCategorizer.any_instance.expects(:auto_categorize).times(times).raises(error)
    end

    def sent_ids(args)
      args[:transactions].map { |t| t[:id] }.sort
    end

    def categorization(transaction, category_name)
      Provider::LlmConcept::AutoCategorization.new(transaction_id: transaction.id, category_name: category_name)
    end
end
