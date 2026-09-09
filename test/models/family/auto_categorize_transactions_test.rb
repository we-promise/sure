require "test_helper"

class Family::AutoCategorizeTransactionsTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    # Fresh family: fixture families carry categorized transactions that
    # would pollute the Bayes training set.
    @family = Family.create!(name: "Bayes Entry Family")
    @account = @family.accounts.create!(name: "Entry test", balance: 100, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
    @llm_provider = mock
  end

  # 10 coffee + 10 groceries = 20 categorized txns over 2 categories, so the
  # Bayes training guard passes (same hand-worked setup as BayesCategorizerTest).
  def train_two_categories
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries) }
  end

  test "bayes handles everything: LLM provider never touched" do
    train_two_categories
    Provider::Registry.expects(:preferred_llm_provider).never

    txn = create_transaction(account: @account, name: "Starbucks Coffee").transaction

    assert_difference "DataEnrichment.count", 1 do
      assert_equal 1, @family.auto_categorize_transactions([ txn.id ])
    end
    assert_equal @coffee, txn.reload.category
    assert_equal "bayes", txn.data_enrichments.find_by(attribute_name: "category_id").source
  end

  test "bayes handles nothing: raises without LLM provider, same contract as today" do
    # No training data → Bayes no-ops; no LLM provider configured → raises.
    txn = create_transaction(account: @account, name: "Something new").transaction

    error = assert_raises(Family::AutoCategorizer::Error) do
      @family.auto_categorize_transactions([ txn.id ])
    end
    assert_equal "No LLM provider for auto-categorization", error.message
    assert_nil txn.reload.category
  end

  test "bayes handles nothing but LLM available: LLM gets all ids and count is unchanged" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)

    txn = create_transaction(account: @account, name: "Novel Shop").transaction
    test_category = @family.categories.create!(name: "Test category")

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: test_category.name)
    ])).once

    assert_difference "DataEnrichment.count", 1 do
      assert_equal 1, @family.auto_categorize_transactions([ txn.id ])
    end
    assert_equal test_category, txn.reload.category
  end

  test "bayes handles some, LLM handles the rest: modified_count sums" do
    train_two_categories
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)

    bayes_txn = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    llm_txn = create_transaction(account: @account, name: "Novel Shop").transaction
    test_category = @family.categories.create!(name: "Test category")

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: llm_txn.id, category_name: test_category.name)
    ])).once

    assert_difference "DataEnrichment.count", 2 do
      assert_equal 2, @family.auto_categorize_transactions([ bayes_txn.id, llm_txn.id ])
    end
    assert_equal @coffee, bayes_txn.reload.category
    assert_equal test_category, llm_txn.reload.category
  end

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization
end
