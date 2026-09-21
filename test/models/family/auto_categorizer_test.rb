require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
  end

  test "auto-categorizes transactions" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Amazon purchase").transaction
    txn3 = create_transaction(account: @account, name: "Netflix subscription").transaction

    test_category = @family.categories.create!(name: "Test category")

    provider_response = provider_success_response([
      AutoCategorization.new(transaction_id: txn1.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn2.id, category_name: test_category.name),
      AutoCategorization.new(transaction_id: txn3.id, category_name: nil)
    ])

    @llm_provider.expects(:auto_categorize).returns(provider_response).once

    assert_difference "DataEnrichment.count", 2 do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_categorize
    end

    assert_equal test_category, txn1.reload.category
    assert_equal test_category, txn2.reload.category
    assert_nil txn3.reload.category

    # After auto-categorization, only successfully categorized transactions are locked
    # txn3 remains enrichable since it didn't get a category (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:category_id).count
  end

  test "raises when provider returns an unsuccessful response" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    @family.categories.create!(name: "Coffee")

    @llm_provider.expects(:auto_categorize)
                 .returns(provider_error_response(Provider::Error.new("Fixed prompt tokens exceed context budget")))

    error = assert_raises(Family::AutoCategorizer::Error) do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    end

    assert_equal "Failed to auto-categorize transactions: Fixed prompt tokens exceed context budget", error.message
  end

  test "logs and raises when no categories are available" do
    @family.categories.destroy_all
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    provider = Provider::Openai.allocate
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.expects(:auto_categorize).never

    assert_difference "DebugLogEntry.count", 1 do
      error = assert_raises(Family::AutoCategorizer::Error) do
        Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
      end
      assert_equal "No categories available for auto-categorization", error.message
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "error", log_entry.level
    assert_equal "AI categorization failed: no categories available", log_entry.message
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal "openai", log_entry.provider_key
    assert_equal [ txn.id ], log_entry.metadata["requested_transaction_ids"]
  end

  test "logs when AI categorization cache handles the batch" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    txn.enrich_attribute(:category_id, category.id, source: "ai")
    txn.lock_attr!(:category_id)
    @llm_provider.expects(:auto_categorize).never

    assert_difference "DebugLogEntry.count", 1 do
      assert_equal 0, Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
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
    @llm_provider.expects(:auto_categorize).never

    assert_difference "DebugLogEntry.count", 1 do
      assert_equal 0, Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
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
    @llm_provider.expects(:auto_categorize).never

    assert_difference "DebugLogEntry.count", 1 do
      assert_equal 0, Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
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

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: llm_txn.id, category_name: category.name)
    ])).once

    assert_difference "DebugLogEntry.count", 2 do
      assert_equal 1, Family::AutoCategorizer.new(@family, transaction_ids: [ cached_txn.id, llm_txn.id ]).auto_categorize
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
    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: category.name)
    ])).once

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

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
    @llm_provider.expects(:auto_categorize).never
    jev.expects(:auto_categorize).returns(provider_success_response([
      CategoryDecision.new(
        transaction_id: txn.id,
        category_name: category.name,
        confidence: 0.97,
        probabilities: { category.name => 0.97 },
        usage: { "cost" => 0.000032 }
      )
    ])).once

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    # The richer struct maps back through the same loop as the LLM shape.
    assert_equal category, txn.reload.category
    assert_equal "jev", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "falls back to the LLM provider when Jev is selected but has no credentials" do
    @family.update!(categorization_provider: "jev")
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    Provider::Registry.stubs(:get_provider).with(:jev).returns(nil)
    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: category.name)
    ])).once

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    assert_equal category, txn.reload.category
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

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

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

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    assert_equal category, txn.reload.category
  end

  test "withholds an answer below the confidence threshold and leaves it retryable" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, category, confidence: 0.52)

    assert_no_difference "DataEnrichment.count" do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
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

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    assert_equal category, txn.reload.category
  end

  test "a threshold never suppresses a provider that reports no confidence" do
    # The LLM providers return a bare category name. Gating them on a confidence
    # they cannot produce would silently stop categorizing altogether.
    @family.update!(categorization_confidence_threshold: 0.9)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: category.name)
    ])).once

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    assert_equal category, txn.reload.category
  end

  # Shadow mode runs the provider that is NOT in use and records the comparison
  # without applying any of its answers.

  test "does not run a shadow provider by default" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal 0.0, @family.effective_categorization_shadow_rate
    Provider::Registry.expects(:get_provider).with(:jev).never
    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: category.name)
    ])).once

    assert_no_difference "CategorizationComparison.count" do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    end
  end

  test "records a disagreement without applying the shadow answer" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    applied = @family.categories.create!(name: "Coffee")
    shadowed = @family.categories.create!(name: "Groceries")

    # Real instances, not bare mocks: the comparison records each provider by
    # its class name, and a Mocha::Mock would be stored as "mock".
    openai = Provider::Openai.allocate
    Provider::Registry.stubs(:preferred_llm_provider).returns(openai)
    openai.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: applied.name)
    ])).once

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
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
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

  test "does not score a missing shadow answer as agreement" do
    # The comparison rows come from the union of both providers' decisions, so
    # one side can be absent entirely. When the other side abstained, both
    # category names are nil — and comparing them directly recorded that as
    # agreement, inflating the rate with rows where nobody agreed on anything.
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "ACH DEBIT 4471920").transaction
    @family.categories.create!(name: "Coffee")

    openai = Provider::Openai.allocate
    Provider::Registry.stubs(:preferred_llm_provider).returns(openai)
    # Answered, but declined to pick a category.
    openai.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: nil)
    ])).once

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    # Returned no decision for this transaction at all.
    jev.expects(:auto_categorize).returns(provider_success_response([])).once

    assert_difference "CategorizationComparison.count", 1 do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
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

    openai = Provider::Openai.allocate
    Provider::Registry.stubs(:preferred_llm_provider).returns(openai)
    openai.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: nil)
    ])).once

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

    Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    assert CategorizationComparison.order(:created_at).last.agreed
  end

  test "a failing shadow provider does not break the run it observes" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: category.name)
    ])).once

    jev = Provider::Jev.allocate
    Provider::Registry.stubs(:get_provider).with(:jev).returns(jev)
    jev.expects(:auto_categorize).raises(Provider::Jev::Error.new("upstream down"))

    assert_nothing_raised do
      Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize
    end

    assert_equal category, txn.reload.category
    assert_equal 0, CategorizationComparison.count
  end

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization
    CategoryDecision = Provider::ClassificationConcept::CategoryDecision

    # Puts the family on Jev and has it return one decision at a given confidence.
    def jev_returning(transaction, category, confidence:)
      @family.update!(categorization_provider: "jev")
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
