require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @llm_provider = mock
    Provider::Registry.stubs(:get_provider).with(:openai).returns(@llm_provider)
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

    result = nil
    assert_difference "DataEnrichment.count", 2 do
      result = Family::AutoCategorizer.new(@family, transaction_ids: [ txn1.id, txn2.id, txn3.id ]).auto_categorize
    end

    # Result is now a struct with modified_count and metadata
    assert_kind_of Family::AutoCategorizer::Result, result
    assert_equal 2, result.modified_count
    assert_equal 2, result.to_i

    # Check metadata
    assert_equal "auto_categorize", result.metadata[:job_type]
    assert_equal 3, result.metadata[:transactions_input]
    assert_equal 2, result.metadata[:transactions_categorized]

    assert_equal test_category, txn1.reload.category
    assert_equal test_category, txn2.reload.category
    assert_nil txn3.reload.category

    # After auto-categorization, only successfully categorized transactions are locked
    # txn3 remains enrichable since it didn't get a category (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:category_id).count
  end

  test "returns result with metadata when no transactions to categorize" do
    result = Family::AutoCategorizer.new(@family, transaction_ids: []).auto_categorize

    assert_kind_of Family::AutoCategorizer::Result, result
    assert_equal 0, result.modified_count
    assert_equal 0, result.metadata[:transactions_input]
    assert_equal 0, result.metadata[:transactions_categorized]
  end

  test "returns result with error metadata when no categories available" do
    # Remove all categories from the family
    @family.categories.destroy_all

    txn = create_transaction(account: @account, name: "Test").transaction

    result = Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ]).auto_categorize

    assert_kind_of Family::AutoCategorizer::Result, result
    assert_equal 0, result.modified_count
    assert_equal "no_categories_available", result.metadata[:error]
  end

  private
    AutoCategorization = Provider::LlmConcept::AutoCategorization
end
