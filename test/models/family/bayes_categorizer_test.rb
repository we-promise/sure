require "test_helper"

class Family::BayesCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    # Fresh family: fixture families carry categorized transactions (e.g.
    # dylan_family's "Starbucks"/"Amazon" → Food & Drink) that would pollute
    # the training set and break the hand-worked 2-category math below.
    @family = Family.create!(name: "Bayes Family")
    @account = @family.accounts.create!(name: "Bayes test", balance: 100, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
    @starbucks = @family.merchants.create!(name: "Starbucks")
    @safeway = @family.merchants.create!(name: "Safeway")
  end

  # 10 coffee + 10 groceries = 20 categorized txns over 2 categories, so the
  # training guard passes. Vocabulary = { starbucks, coffee, safeway,
  # groceries }, |V| = 4. Each class has 20 total tokens (10 txns x 2).
  def train_two_categories
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries) }
  end

  test "no-op before enough training data" do
    categorizer = Family::BayesCategorizer.new(@family)

    assert_not categorizer.enough_training_data?

    5.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }

    assert_not categorizer.enough_training_data?
    uncategorized = create_transaction(account: @account, name: "Starbucks Coffee")

    assert_nil categorizer.classify(uncategorized.transaction)
    assert_difference "DataEnrichment.count", 0 do
      result = categorizer.classify_and_apply([ uncategorized.transaction.id ])
      assert_equal [], result.categorized_ids
      assert_equal 0, result.modified_count
    end
    assert_nil uncategorized.transaction.reload.category
  end

  test "separable merchants classify above threshold with hand-worked confidence" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)
    assert categorizer.enough_training_data?

    txn = create_transaction(account: @account, name: "Starbucks Coffee")

    category_id, confidence = categorizer.classify(txn.transaction)

    assert_equal @coffee.id, category_id

    # Hand-worked multinomial NB, Laplace add-1, uniform prior:
    #   P(coffee)     = 0.5, total tokens = 20, |V| = 4
    #   score_coffee  = ln(0.5) + ln(11/24) + ln(11/24) ≈ -2.2535
    #   score_other   = ln(0.5) + ln(1/24)  + ln(1/24)  ≈ -7.0493
    #   softmax(coffee) = 1 / (1 + e^(score_other - score_coffee))
    #                   = 1 / (1 + e^-4.7958) ≈ 0.9918
    assert_in_delta 0.9918, confidence, 0.001
    assert_operator confidence, :>=, Family::BayesCategorizer::CONFIDENCE_THRESHOLD
  end

  test "wholly novel tokens stay unclassified even when class corpora are lopsided" do
    # The symmetric fixture above cannot catch this: with equal token totals an
    # unknown token contributes the same smoothed likelihood to every class and
    # the bias cancels. Give one class a much larger corpus and an unseen
    # description would otherwise land on the smaller class with high
    # confidence, purely because 1/(total + |V|) is larger there.
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee) }
    10.times do
      create_transaction(
        account: @account,
        name: "Safeway Groceries Produce Dairy Bakery Deli Frozen Pantry",
        category: @groceries
      )
    end

    categorizer = Family::BayesCategorizer.new(@family)
    assert categorizer.enough_training_data?

    novel = create_transaction(account: @account, name: "Zzyzx Blorptronics")

    assert_nil categorizer.classify(novel.transaction),
      "a description with no known tokens must not be classified from corpus-size bias alone"
  end

  test "novel merchant below threshold is left alone" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)

    novel = create_transaction(account: @account, name: "New Shop", merchant: @family.merchants.create!(name: "Unknown Emporium"))

    assert_nil categorizer.classify(novel.transaction)
    assert_difference "DataEnrichment.count", 0 do
      result = categorizer.classify_and_apply([ novel.transaction.id ])
      assert_equal [], result.categorized_ids
      assert_equal 0, result.modified_count
    end
    assert_nil novel.transaction.reload.category
  end

  test "mixed case and merchant signals classify and modified_count sums correctly" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)

    # Same tokens as "starbucks coffee" — downcase normalization.
    txn1 = create_transaction(account: @account, name: "STARBUCKS Coffee")
    # Name is generic but the merchant name carries the signal.
    txn2 = create_transaction(account: @account, name: "Purchase", merchant: @starbucks)
    # Already categorized → outside scope, must not be counted.
    txn3 = create_transaction(account: @account, name: "Safeway Groceries", category: @groceries)

    assert_difference "DataEnrichment.count", 2 do
      result = categorizer.classify_and_apply([ txn1.transaction.id, txn2.transaction.id, txn3.transaction.id ])
      assert_equal [ txn1.transaction.id, txn2.transaction.id ].sort, result.categorized_ids.sort
      assert_equal 2, result.modified_count
    end

    assert_equal @coffee, txn1.transaction.reload.category
    assert_equal @coffee, txn2.transaction.reload.category
    assert_equal @groceries, txn3.transaction.reload.category

    enrichment = txn1.transaction.data_enrichments.find_by(attribute_name: "category_id")
    assert_equal "bayes", enrichment.source
  end

  test "classify_and_apply returns categorized_ids and modified_count separately" do
    train_two_categories
    categorizer = Family::BayesCategorizer.new(@family)

    # A transaction whose category is already the predicted one is out of the
    # nil-category scope entirely — filtered before enrichment.
    txn = create_transaction(account: @account, name: "Starbucks Coffee")

    result = categorizer.classify_and_apply([ txn.transaction.id ])
    assert_kind_of Family::BayesCategorizer::Result, result
    assert_equal [ txn.transaction.id ], result.categorized_ids
    assert_equal 1, result.modified_count
  end
end
