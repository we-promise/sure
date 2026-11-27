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

  # Two uncategorized legs that Auto Match suggests as one transfer. Returns
  # [outflow, inflow] transactions.
  def suggest_transfer(name)
    # Auto Match only pairs accounts that someone in the family can write to.
    @family.users.create!(email: "member@example.com", password: "password123!A", first_name: "Test", last_name: "Member", role: "member") unless @family.users.exists?
    to_account = @family.accounts.create!(name: "Savings", balance: 100, currency: "USD", accountable: Depository.new)
    outflow = create_transaction(account: @account, name: name, amount: 42).transaction
    inflow = create_transaction(account: to_account, name: name, amount: -42).transaction
    @family.auto_match_transfers!
    assert_predicate outflow.reload.transfer, :pending?
    [ outflow, inflow ]
  end

  test "the rule's auto-categorize is the LLM only, even when Bayes would know" do
    train_two_categories
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
    txn = create_transaction(account: @account, name: "Starbucks Coffee").transaction

    @llm_provider.expects(:auto_categorize).returns(provider_success_response([
      AutoCategorization.new(transaction_id: txn.id, category_name: @groceries.name)
    ])).once

    assert_equal 1, @family.auto_categorize_transactions([ txn.id ])
    assert_equal @groceries, txn.reload.category
    assert_ai_categorization_log(transaction_ids: [ txn.id ])
  end

  test "without a provider the LLM raises" do
    txn = create_transaction(account: @account, name: "Something new").transaction

    error = assert_raises(Family::AutoCategorizer::Error) do
      @family.auto_categorize_transactions([ txn.id ])
    end
    assert_equal "No LLM provider for auto-categorization", error.message
  end

  test "Bayes categorizes the uncategorized, unlocked transactions and logs the count" do
    train_two_categories
    Provider::Registry.expects(:preferred_llm_provider).never
    coffee = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    novel = create_transaction(account: @account, name: "Novel Shop").transaction
    locked = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    locked.lock_attr!(:category_id)

    assert_equal 1, @family.bayes_categorize_uncategorized
    assert_equal @coffee, coffee.reload.category
    assert_nil novel.reload.category
    assert_nil locked.reload.category

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "Bayesian categorization categorized 1 of 2 transactions", log_entry.message
    assert_equal 1, log_entry.metadata["categorized_count"]
  end

  test "Bayes leaves transfer legs uncategorized" do
    train_two_categories
    transfer = create_transaction(account: @account, name: "Starbucks Coffee", kind: "funds_movement").transaction

    assert_equal 0, @family.bayes_categorize_uncategorized
    assert_nil transfer.reload.category
  end

  # Auto Match runs before the rules after every sync, so its suggestions
  # exist by the time the classifier does. Until the user confirms one, both
  # legs keep the kind "standard", but they are one movement between the
  # user's own accounts, not spending and income to put a guess on.
  test "Bayes leaves both legs of a suggested transfer uncategorized" do
    train_two_categories
    outflow, inflow = suggest_transfer("Starbucks Coffee")
    ordinary = create_transaction(account: @account, name: "Starbucks Coffee").transaction

    assert_equal 1, @family.bayes_categorize_uncategorized
    assert_nil outflow.reload.category
    assert_nil inflow.reload.category
    assert_equal @coffee, ordinary.reload.category
  end

  test "Bayes leaves a suggested transfer's legs alone in a rule's scope too" do
    train_two_categories
    outflow, inflow = suggest_transfer("Starbucks Coffee")

    assert_equal 0, @family.bayes_categorize_uncategorized(@family.transactions)
    assert_nil outflow.reload.category
    assert_nil inflow.reload.category
  end

  test "Bayes categorizes the legs again once the suggestion is rejected" do
    train_two_categories
    outflow, inflow = suggest_transfer("Starbucks Coffee")
    assert_equal 0, @family.bayes_categorize_uncategorized

    outflow.transfer.reject!

    assert_equal 2, @family.bayes_categorize_uncategorized
    assert_equal @coffee, outflow.reload.category
    assert_equal @coffee, inflow.reload.category
  end

  test "Bayes categorizes a confirmed loan payment but not the transfer's other leg" do
    train_two_categories
    loan = @family.accounts.create!(name: "Car loan", balance: 1000, currency: "USD", accountable: Loan.new)
    outflow = create_transaction(account: @account, name: "Starbucks Coffee", amount: 42).transaction
    inflow = create_transaction(account: loan, name: "Starbucks Coffee", amount: -42).transaction
    Transfer.create!(outflow_transaction: outflow, inflow_transaction: inflow, amount: 42).confirm!

    assert_equal 1, @family.bayes_categorize_uncategorized
    assert_equal "loan_payment", outflow.reload.kind
    assert_equal @coffee, outflow.category
    assert_nil inflow.reload.category
  end

  # Excluding a transaction takes it out of every report on purpose (a house
  # deposit, a loan drawdown). A guessed category on it is noise at best, and a
  # large one-off reads like the nearest frequent label (rent).
  test "Bayes leaves excluded transactions uncategorized" do
    train_two_categories
    excluded = create_transaction(account: @account, name: "Starbucks Coffee", excluded: true).transaction
    included = create_transaction(account: @account, name: "Starbucks Coffee").transaction

    assert_equal 1, @family.bayes_categorize_uncategorized
    assert_nil excluded.reload.category
    assert_equal @coffee, included.reload.category
  end

  test "Bayes skips excluded transactions in a rule's scope too" do
    train_two_categories
    excluded = create_transaction(account: @account, name: "Starbucks Coffee", excluded: true).transaction

    assert_equal 0, @family.bayes_categorize_uncategorized(@family.transactions)
    assert_nil excluded.reload.category
  end

  test "the LLM is not asked about excluded transactions" do
    Provider::Registry.stubs(:preferred_llm_provider).returns(@llm_provider)
    excluded = create_transaction(account: @account, name: "House deposit", excluded: true).transaction

    @llm_provider.expects(:auto_categorize).never

    assert_equal 0, @family.auto_categorize_transactions([ excluded.id ])
    assert_nil excluded.reload.category
  end

  test "clearing Bayes locks unlocks only what Bayes locked and still has its pick" do
    train_two_categories
    @family.update_bayes_settings!(lock_results: true)
    kept = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    changed = create_transaction(account: @account, name: "Starbucks Coffee").transaction
    @family.bayes_categorize_uncategorized
    changed.update!(category: @groceries)
    user_locked = create_transaction(account: @account, name: "Mine", category: @coffee).transaction
    user_locked.lock_attr!(:category_id)

    assert_equal 1, @family.clear_bayes_locks!

    assert_not kept.reload.locked?(:category_id)
    assert_equal @coffee, kept.category
    assert_nil kept.data_enrichments.find_by(attribute_name: "category_id").metadata["locked_by_bayes"]
    assert changed.reload.locked?(:category_id)
    assert user_locked.reload.locked?(:category_id)
  end

  test "clearing Bayes locks also unlocks the merchants the matcher locked and still has" do
    merchant = @family.merchants.create!(name: "Netflix")
    other = @family.merchants.create!(name: "Hulu")
    kept, changed = Array.new(2) do
      create_transaction(account: @account, name: "Netflix com").transaction.tap do |transaction|
        transaction.enrich_attribute(:merchant_id, merchant.id, source: "similar", metadata: { locked_by_similar: true })
        transaction.lock_attr!(:merchant_id)
      end
    end
    changed.update!(merchant: other)

    assert_equal 1, @family.clear_bayes_locks!

    assert_not kept.reload.locked?(:merchant_id)
    assert_equal merchant, kept.merchant
    assert_nil kept.data_enrichments.find_by(attribute_name: "merchant_id").metadata["locked_by_similar"]
    assert changed.reload.locked?(:merchant_id)
  end

  test "clearing Bayes locks is all or none" do
    merchant = @family.merchants.create!(name: "Netflix")
    transaction = create_transaction(account: @account, name: "Netflix com").transaction
    transaction.enrich_attribute(:merchant_id, merchant.id, source: "similar", metadata: { locked_by_similar: true })
    transaction.lock_attr!(:merchant_id)
    ActiveRecord::Relation.any_instance.stubs(:touch_all).raises(ActiveRecord::StatementInvalid, "boom")

    assert_raises(ActiveRecord::StatementInvalid) { @family.clear_bayes_locks! }

    assert transaction.reload.locked?(:merchant_id)
    assert transaction.data_enrichments.find_by(attribute_name: "merchant_id").metadata["locked_by_similar"]
  end

  private
    def assert_ai_categorization_log(transaction_ids:, categorized_transaction_ids: transaction_ids)
      log_entry = DebugLogEntry.order(:created_at).last

      assert_equal "auto_categorization", log_entry.category
      assert_equal "info", log_entry.level
      assert_equal "AI categorization completed", log_entry.message
      assert_equal "Family::AutoCategorizer", log_entry.source
      assert_equal @family, log_entry.family
      assert_equal transaction_ids, log_entry.metadata["requested_transaction_ids"]
      assert_equal categorized_transaction_ids, log_entry.metadata["categorized_transaction_ids"]
      assert_equal categorized_transaction_ids.size, log_entry.metadata["modified_count"]
    end

    AutoCategorization = Provider::LlmConcept::AutoCategorization
end
