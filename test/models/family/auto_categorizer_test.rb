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

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization
end
