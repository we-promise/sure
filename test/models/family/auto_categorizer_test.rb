require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    use_ai_routes
  end

  test "auto-categorizes transactions" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Amazon purchase").transaction
    txn3 = create_transaction(account: @account, name: "Netflix subscription").transaction

    test_category = @family.categories.create!(name: "Test category")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn1.id, category_name: test_category.name },
      { transaction_id: txn2.id, category_name: test_category.name },
      { transaction_id: txn3.id, category_name: nil }
    ] })

    assert_difference "DataEnrichment.count", 2 do
      categorize([ txn1.id, txn2.id, txn3.id ])
    end

    assert_equal test_category, txn1.reload.category
    assert_equal test_category, txn2.reload.category
    assert_nil txn3.reload.category

    # After auto-categorization, only successfully categorized transactions are locked
    # txn3 remains enrichable since it didn't get a category (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:category_id).count
  end

  test "a rule run's progress moves with each batch" do
    use_ai_model_settings(batch_size: 2)
    category = @family.categories.create!(name: "Coffee")
    ids = 3.times.map { |i| create_transaction(account: @account, name: "Coffee #{i}").transaction.id }
    rule_run = RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 1,
                               transactions_queued: 3, executed_at: Time.current)
    rule_run.await_ai!(3)
    stub_ai(:categorize) do |request|
      batch = request.schema.dig(:properties, :categorizations, :items, :properties, :transaction_id, :enum)
      { categorizations: batch.map { { transaction_id: _1, category_name: category.name } } }
    end

    Ai::GenerationJob.perform_later(:categorize, { ids:, family_id: @family.id, rule_run_id: rule_run.id })
    progress = []
    until enqueued_jobs.empty?
      ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys)
      progress << rule_run.reload.slice(:transactions_awaiting_ai, :transactions_modified, :status).values
    end

    assert_equal [ [ 1, 2, "pending" ], [ 0, 3, "success" ] ], progress
  end

  test "a failed generation fails the rule run's job and is logged" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    @family.categories.create!(name: "Coffee")
    rule_run = RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 1,
                               transactions_queued: 1, executed_at: Time.current)
    stub_ai(:categorize, raises: Ai::Error::InvalidOutput.new("no JSON"))

    assert_difference -> { DebugLogEntry.where(message: "AI categorization failed").count }, 1 do
      Ai::GenerationJob.perform_now(:categorize, { ids: [ txn.id ], family_id: @family.id, rule_run_id: rule_run.id })
    end

    assert_equal "failed", rule_run.reload.status
    assert_includes rule_run.error_message, "no JSON"
  end

  test "no categories fails the rule run's job, logs why, and asks no model" do
    @family.categories.destroy_all
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    rule_run = RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 1,
                               transactions_queued: 1, executed_at: Time.current)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    Ai::GenerationJob.perform_now(:categorize, { ids: [ txn.id ], family_id: @family.id, rule_run_id: rule_run.id })

    assert_equal "failed", rule_run.reload.status
    assert_includes rule_run.error_message, "No categories available"
    log_entry = DebugLogEntry.find_by!(message: "AI categorization failed: no categories available")
    assert_equal "auto_categorization", log_entry.category
    assert_equal "error", log_entry.level
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal [ txn.id ], log_entry.metadata["requested_transaction_ids"]
  end

  test "sends the family's categories and transactions through the route's prompt" do
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    @family.categories.create!(name: "Coffee")
    requests = stub_ai(:categorize, returns: { categorizations: [] })

    categorize([ txn.id ])

    assert_includes requests.first.instructions, "Your job is to auto-categorize"
    assert_includes requests.first.input, "Blue Bottle Coffee"
    assert_includes requests.first.input, "\"name\":\"Coffee\""
    assert_equal "auto_categorize_personal_finance_transactions", requests.first.schema_name
  end

  test "logs when AI categorization cache handles the batch" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    txn.enrich_attribute(:category_id, category.id, source: "ai")
    txn.lock_attr!(:category_id)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "AI categorization cache used", log_entry.message
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal [ txn.id ], log_entry.metadata["cached_transaction_ids"]
  end

  test "logs when categorization is blocked by enrichment protection" do
    txn = create_transaction(account: @account, name: "Protected transaction").transaction
    txn.lock_attr!(:category_id)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "AI categorization blocked by enrichment protection", log_entry.message
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal [ txn.id ], log_entry.metadata["blocked_transaction_ids"]
  end

  test "does not treat a user-overridden AI category as cached" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    ai_category = @family.categories.create!(name: "AI category")
    user_category = @family.categories.create!(name: "User category")
    txn.enrich_attribute(:category_id, ai_category.id, source: "ai")
    txn.lock_attr!(:category_id)
    txn.update!(category_id: user_category.id)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "AI categorization blocked by enrichment protection", log_entry.message
    assert_equal [ txn.id ], log_entry.metadata["blocked_transaction_ids"]
  end

  test "logs AI cache usage alongside LLM categorization" do
    cached_txn = create_transaction(account: @account, name: "Coffee shop").transaction
    llm_txn = create_transaction(account: @account, name: "Bakery").transaction
    category = @family.categories.create!(name: "Coffee")
    cached_txn.enrich_attribute(:category_id, category.id, source: "ai")
    cached_txn.lock_attr!(:category_id)

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: llm_txn.id, category_name: category.name }
    ] })

    assert_difference "DebugLogEntry.count", 2 do
      categorize([ cached_txn.id, llm_txn.id ])
    end

    entries = DebugLogEntry.order(:created_at).last(2)
    cache_entry = entries.find { |entry| entry.message == "AI categorization cache used" }
    ai_entry = entries.find { |entry| entry.message == "AI categorization completed" }

    assert_equal [ cached_txn.id ], cache_entry.metadata["cached_transaction_ids"]
    assert_equal [ cached_txn.id, llm_txn.id ], ai_entry.metadata["requested_transaction_ids"]
    assert_equal [ cached_txn.id ], ai_entry.metadata["cached_transaction_ids"]
    assert_equal [ llm_txn.id ], ai_entry.metadata["categorized_transaction_ids"]
  end

  # Jev answers when the categorize route lists it: the instance's choice, read
  # by the deprecated ENV path. Preview gates whether the selector is offered (see
  # docs/llm-guides/gating-a-preview-feature.md), never what gets used.

  test "uses the LLM by default" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal "llm", Ai::LegacyEnvConfig.categorization_provider
    requests = stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
    assert_instance_of Ai::Transport::Base::Request, requests.sole
  end

  test "uses Jev when the categorize route lists it" do
    use_ai_routes(categorize: %w[jev/jev-latest])
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    category = @family.categories.create!(name: "Coffee")
    requests = stub_ai(:categorize) { { txn.id => { category: [ category.name, 0.97 ] } } }

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
    assert_instance_of Ai::Transport::Base::JudgeRequest, requests.sole
    assert_equal "jev", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "the instance's Jev choice routes categorize to Jev, and its shadow to the LLM" do
    Ai::Config.override = nil
    Setting.categorization_provider = "jev"

    with_env_overrides("OPENAI_ACCESS_TOKEN" => "sk-test", "JEV_API_KEY" => "jev-test") do
      assert_equal [ "jev" ], Ai.plan(:categorize, family: @family).routes.map { _1.endpoint.name }
      assert_equal [ "openai" ], Ai.plan(:shadow_categorize, family: @family).routes.map { _1.endpoint.name }
    end
  ensure
    Setting.categorization_provider = nil
  end

  test "falls back to the LLM when Jev is chosen but has no key" do
    Ai::Config.override = nil
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    stub_ai(:categorize, returns: { categorizations: [ { transaction_id: txn.id, category_name: category.name } ] })

    with_env_overrides("OPENAI_ACCESS_TOKEN" => "sk-test", "CATEGORIZATION_PROVIDER" => "jev") do
      assert_no_difference -> { DebugLogEntry.where(level: "error").count } do
        categorize([ txn.id ])
      end
    end

    assert_equal category, txn.reload.category
  end

  test "logs an unsupported Jev endpoint when categorization falls back to the LLM" do
    Ai::Config.override = nil
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    stub_ai(:categorize, returns: { categorizations: [ { transaction_id: txn.id, category_name: category.name } ] })

    with_env_overrides(
      "OPENAI_ACCESS_TOKEN" => "sk-test", "CATEGORIZATION_PROVIDER" => "jev", "JEV_API_KEY" => "test_api_key",
      "JEV_ENDPOINT" => "https://someone:s3cret@gw.example.com/v1?api_key=QUERYSECRET#frag" # pipelock:ignore Credential in URL
    ) do
      assert_difference "DebugLogEntry.count", 2 do
        categorize([ txn.id ])
      end
    end

    assert_equal category, txn.reload.category
    entry = DebugLogEntry.where(message: "Jev is misconfigured; falling back to the LLM provider").sole
    assert_equal "auto_categorization", entry.category
    assert_equal "error", entry.level
    assert_equal "jev", entry.provider_key
    assert_equal @family, entry.family
    assert_equal "https://gw.example.com/v1", entry.metadata["endpoint"]
    assert_equal "path", entry.metadata["reason"]
    serialized = entry.metadata.to_json
    assert_not_includes serialized, "s3cret"
    assert_not_includes serialized, "QUERYSECRET"
    assert_not_includes serialized, "frag"
  end

  # Confidence has to change behaviour, not just appear in logs. Below the threshold the answer
  # is withheld and the transaction is left unlocked, so a later run can still correct it. Only
  # a model with calibrated confidence is gated.

  test "withholds a calibrated answer that carries no confidence at all" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, RubyLLM::Choice.new(choice: category.name, probabilities: {}, confidence: nil))

    categorize([ txn.id ])

    assert_nil txn.reload.category
    assert_includes @account.transactions.reload.enrichable(:category_id), txn
  end

  test "applies every answer when the threshold is zero" do
    @family.update!(categorization_confidence_threshold: 0)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal 0.0, @family.effective_categorization_confidence_threshold
    jev_returning(txn, [ category.name, 0.12 ])

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "withholds an answer below the confidence threshold and leaves it retryable" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, [ category.name, 0.52 ])

    assert_no_difference "DataEnrichment.count" do
      categorize([ txn.id ])
    end

    assert_nil txn.reload.category
    assert_includes @account.transactions.reload.enrichable(:category_id), txn

    entry = DebugLogEntry.order(:created_at).last
    withheld = entry.metadata["withheld_low_confidence"].sole
    assert_equal txn.id, withheld["transaction_id"]
    assert_in_delta 0.52, withheld["confidence"], 0.001
  end

  test "applies an answer at or above the confidence threshold" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, [ category.name, 0.97 ])

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "a threshold never suppresses a model without calibrated confidence" do
    # The LLMs return a bare category name, and a self-hosted judge hasn't had its confidence
    # checked. Gating them on it would silently stop categorizing.
    @family.update!(categorization_confidence_threshold: 0.9)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [ { transaction_id: txn.id, category_name: category.name } ] })
    categorize([ txn.id ])
    assert_equal category, txn.reload.category

    other = create_transaction(account: @account, name: "Coffee again").transaction
    local = Ai::Config::Endpoint.new(name: :jev_local, protocol: :jev, preset: :jev_local, base_url: "http://jev:8080", location: :local)
    Ai::Config.override = AiTestHelper.build_ai_config([ Ai::Config::Model.new(endpoint: local, name: "jev-latest", capabilities: %i[judge]) ],
                                                       { categorize: [ "jev_local/jev-latest" ] })
    stub_ai(:categorize) { { other.id => { category: [ category.name, 0.3 ] } } }
    categorize([ other.id ])
    assert_equal category, other.reload.category
  end

  private
    def categorize(transaction_ids)
      Ai::GenerationJob.perform_now(:categorize, { ids: transaction_ids, family_id: @family.id })
    end

    # Routes categorize to the test setup's cloud Jev and has it give one answer.
    def jev_returning(transaction, answer)
      use_ai_routes(categorize: %w[jev/jev-latest])
      stub_ai(:categorize) { { transaction.id => { category: answer } } }
    end
end
