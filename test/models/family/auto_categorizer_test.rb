require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

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

  test "logs when no categories are available, and asks no model" do
    @family.categories.destroy_all
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "error", log_entry.level
    assert_equal "AI categorization failed: no categories available", log_entry.message
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

  # Jev runs only when the family has chosen it AND credentials are configured.
  # The choice is a family column, not the preview flag: preview gates whether
  # the selector is offered (see docs/llm-guides/gating-a-preview-feature.md),
  # never what gets used. Every other install keeps the LLM path.

  test "uses the LLM provider by default" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal "llm", @family.categorization_provider
    # Not even looked up: the choice short-circuits before the registry.
    Provider::Registry.expects(:get_provider).with(:jev).never
    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "uses Jev when the family selects it and it is configured" do
    @family.update!(categorization_provider: "jev")
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    category = @family.categories.create!(name: "Coffee")

    # A real instance, not a bare mock: DebugLogEntry derives provider_key from
    # the class name, so a Mocha::Mock would log "mock".
    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    use_ai_routes(categorize: %w[jev/jev-latest openai/gpt-4.1-mini])
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }
    jev.expects(:auto_categorize).returns(provider_success_response([
      CategoryDecision.new(
        transaction_id: txn.id,
        category_name: category.name,
        confidence: 0.97,
        probabilities: { category.name => 0.97 },
        usage: { "cost" => 0.000032 }
      )
    ])).once

    categorize([ txn.id ])

    # The richer struct maps back through the same loop as the LLM shape.
    assert_equal category, txn.reload.category
    assert_equal "jev", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "falls back to the LLM provider when Jev is selected but has no credentials" do
    @family.update!(categorization_provider: "jev")
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    Provider::Registry.stubs(:get_provider).with(:jev).returns(nil)
    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "logs the rejected Jev endpoint only when categorization actually runs" do
    @family.update!(categorization_provider: "jev")
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    with_env_overrides(
      "JEV_API_KEY" => "test_api_key",
      "JEV_ENDPOINT" => "http://someone:s3cret@gw.example.com/v1?api_key=QUERYSECRET#frag" # pipelock:ignore Credential in URL
    ) do
      assert_difference "DebugLogEntry.count", 2 do
        categorize([ txn.id ])
      end
    end

    entry = DebugLogEntry.where(message: "Jev is misconfigured; falling back to the LLM provider").sole
    assert_equal "auto_categorization", entry.category
    assert_equal "error", entry.level
    assert_equal "jev", entry.provider_key
    assert_equal @family, entry.family
    assert_equal "http://gw.example.com/v1", entry.metadata["endpoint"]
    assert_equal "Provider::Jev::Error", entry.metadata["error_class"]

    # error_message embeds the endpoint the constructor rejected, so it leaks
    # just as readily as the endpoint field if it is not redacted at the raise.
    serialized = entry.metadata.to_json
    assert_not_includes serialized, "s3cret"
    assert_not_includes serialized, "QUERYSECRET"
    assert_not_includes serialized, "frag"
  end

  # Confidence has to change behaviour, not just appear in logs. Below the
  # threshold the answer is withheld and the transaction is left unlocked, so a
  # later run can still correct it.

  test "withholds a classification answer that carries no confidence at all" do
    # Previously the gate returned false on a nil confidence, which was there to
    # avoid gating the LLM providers. That also let a malformed classification
    # answer through — the one case where withholding matters most, since we
    # have no idea how good it is.
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, category, confidence: nil)

    categorize([ txn.id ])

    assert_nil txn.reload.category
    assert_includes @account.transactions.reload.enrichable(:category_id), txn
  end

  test "applies every answer when the threshold is zero" do
    # Set explicitly rather than leaning on the column default, which is 0.7 —
    # this test is about the zero-threshold behaviour, not about what ships.
    @family.update!(categorization_confidence_threshold: 0)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal 0.0, @family.effective_categorization_confidence_threshold
    jev_returning(txn, category, confidence: 0.12)

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "withholds an answer below the confidence threshold and leaves it retryable" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, category, confidence: 0.52)

    assert_no_difference "DataEnrichment.count" do
      categorize([ txn.id ])
    end

    assert_nil txn.reload.category
    # Unlocked, so it stays eligible for a later attempt.
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

    jev_returning(txn, category, confidence: 0.97)

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "a threshold never suppresses a provider that reports no confidence" do
    # The LLM providers return a bare category name. Gating them on a confidence
    # they cannot produce would silently stop categorizing altogether.
    @family.update!(categorization_confidence_threshold: 0.9)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  # Shadow mode runs the provider that is NOT in use and records the comparison
  # without applying any of its answers.

  test "does not run a shadow provider by default" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal 0.0, @family.effective_categorization_shadow_rate
    Provider::Registry.expects(:get_provider).with(:jev).never
    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    assert_no_difference "CategorizationComparison.count" do
      categorize([ txn.id ])
    end
  end

  test "records a disagreement without applying the shadow answer" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    applied = @family.categories.create!(name: "Coffee")
    shadowed = @family.categories.create!(name: "Groceries")

    # Real instances, not bare mocks: the comparison records each provider by
    # its class name, and a Mocha::Mock would be stored as "mock".
    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: applied.name }
    ] })

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    jev.expects(:auto_categorize).returns(provider_success_response([
      CategoryDecision.new(
        transaction_id: txn.id,
        category_name: shadowed.name,
        confidence: 0.88,
        probabilities: { shadowed.name => 0.88 },
        usage: { "cost" => 0.000032 }
      )
    ])).once

    assert_difference "CategorizationComparison.count", 1 do
      categorize([ txn.id ])
    end

    # The incumbent's answer is the one that lands.
    assert_equal applied, txn.reload.category

    comparison = CategorizationComparison.order(:created_at).last
    assert_not comparison.agreed
    assert_equal "openai", comparison.applied_provider
    assert_equal "jev", comparison.shadow_provider
    assert_equal applied.name, comparison.applied_category_name
    assert_equal shadowed.name, comparison.shadow_category_name
    assert_in_delta 0.88, comparison.shadow_confidence, 0.001
  end

  test "the shadow compares only the transactions in this job's batch" do
    @family.update!(categorization_shadow_rate: 1.0)
    category = @family.categories.create!(name: "Coffee")
    txns = Array.new(3) { create_transaction(account: @account, name: "Blue Bottle #{_1}").transaction }
    stub_ai(:categorize) { |request| { categorizations: request.input.scan(/ID: (\S+),/).flatten.map { { transaction_id: _1, category_name: category.name } } } }

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    shadowed = []
    jev.stubs(:auto_categorize).with { |transactions:, **| shadowed << transactions.map { _1[:id] } }.returns(provider_success_response([]))

    with_ai_model_settings(batch_size: 2) { categorize(txns.map(&:id)) }

    assert_equal [ 2 ], shadowed.map(&:size), "the first job's batch only"
  end

  test "does not score a missing shadow answer as agreement" do
    # The comparison rows come from the union of both providers' decisions, so
    # one side can be absent entirely. When the other side abstained, both
    # category names are nil — and comparing them directly recorded that as
    # agreement, inflating the rate with rows where nobody agreed on anything.
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "ACH DEBIT 4471920").transaction
    @family.categories.create!(name: "Coffee")

    # Answered, but declined to pick a category.
    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: nil }
    ] })

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    # Returned no decision for this transaction at all.
    jev.expects(:auto_categorize).returns(provider_success_response([])).once

    assert_difference "CategorizationComparison.count", 1 do
      categorize([ txn.id ])
    end

    comparison = CategorizationComparison.order(:created_at).last
    assert_not comparison.agreed
    assert_nil comparison.shadow_category_name
  end

  test "counts a shared abstention as agreement" do
    # The other half of the rule: both providers answering "no category" is a
    # real agreement, and must not be swept up by the fix above.
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "ACH DEBIT 4471920").transaction
    @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: nil }
    ] })

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    jev.expects(:auto_categorize).returns(provider_success_response([
      CategoryDecision.new(
        transaction_id: txn.id,
        category_name: nil,
        confidence: 0.94,
        probabilities: {},
        usage: {}
      )
    ])).once

    categorize([ txn.id ])

    assert CategorizationComparison.order(:created_at).last.agreed
  end

  test "a failing shadow provider does not break the run it observes" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    jev.expects(:auto_categorize).raises(Provider::Jev::Error.new("upstream down"))

    assert_nothing_raised do
      categorize([ txn.id ])
    end

    assert_equal category, txn.reload.category
    assert_equal 0, CategorizationComparison.count
  end

  test "logs a rejected Jev endpoint when it was due to shadow the run" do
    @family.update!(categorization_provider: "llm", categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    with_env_overrides("JEV_API_KEY" => "test_api_key", "JEV_ENDPOINT" => "http://gw.example.com/v1") do
      categorize([ txn.id ])
    end

    entry = DebugLogEntry.where(message: "Jev is misconfigured; skipping the shadow comparison").sole
    assert_equal "Provider::Jev::Error", entry.metadata["error_class"]
    assert_equal category, txn.reload.category
  end

  private
    CategoryDecision = Provider::ClassificationConcept::CategoryDecision

    def categorize(transaction_ids)
      Ai::GenerationJob.perform_now(:categorize, { ids: transaction_ids, family_id: @family.id })
    end

    # Puts the family on Jev and has it return one decision at a given confidence.
    def jev_returning(transaction, category, confidence:)
      @family.update!(categorization_provider: "jev")
      use_ai_routes(categorize: %w[jev/jev-latest openai/gpt-4.1-mini])
      jev = Provider::Jev.allocate
      Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
      jev.expects(:auto_categorize).returns(provider_success_response([
        CategoryDecision.new(
          transaction_id: transaction.id,
          category_name: category.name,
          confidence: confidence,
          probabilities: { category.name => confidence },
          usage: { "cost" => 0.000032 }
        )
      ])).once
      jev
    end
end
