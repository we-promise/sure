require "test_helper"

class Provider::Truelayer::CategoryTaxonomyTest < ActiveSupport::TestCase
  T = Provider::Truelayer::CategoryTaxonomy

  test "resolves classification subcategory when present" do
    txn = { transaction_classification: [ "Food & Dining", "Restaurants" ], amount: -10.0 }
    result = T.resolve(txn)
    assert_includes result[:aliases], "restaurant"
  end

  test "falls back to parent classification when subcategory unknown" do
    txn = { transaction_classification: [ "Food & Dining", "ObscureSubThatDoesntExist" ], amount: -10.0 }
    result = T.resolve(txn)
    # Parent itself provides aliases pointing at Food & Drink-equivalent names.
    assert_includes result[:aliases], "food and drink"
  end

  test "falls back to transaction_category=FEE_CHARGE when classification missing" do
    txn = { transaction_classification: nil, transaction_category: "FEE_CHARGE", amount: -3.0 }
    result = T.resolve(txn)
    assert_includes result[:aliases], "fee"
  end

  test "INTEREST with positive amount resolves to income" do
    txn = { transaction_classification: nil, transaction_category: "INTEREST", amount: 5.0 }
    result = T.resolve(txn)
    assert_includes result[:aliases].map(&:downcase), "interest"
    assert_includes result[:parent_aliases], "income"
  end

  test "INTEREST with negative amount resolves to expense (interest charge)" do
    txn = { transaction_classification: nil, transaction_category: "INTEREST", amount: -5.0 }
    result = T.resolve(txn)
    assert_includes result[:parent_aliases], "fee"
  end

  test "DIVIDEND resolves to investment income" do
    txn = { transaction_classification: nil, transaction_category: "DIVIDEND", amount: 50.0 }
    result = T.resolve(txn)
    refute_nil result
    assert_includes result[:aliases].map(&:downcase), "dividend"
  end

  test "non-whitelisted transaction_category without classification returns nil" do
    %w[PURCHASE TRANSFER DEBIT CREDIT OTHER UNKNOWN CHEQUE CASH ATM].each do |cat|
      txn = { transaction_classification: nil, transaction_category: cat, amount: -1.0 }
      assert_nil T.resolve(txn), "expected nil for #{cat}"
    end
  end

  test "returns nil for blank input" do
    assert_nil T.resolve({})
    assert_nil T.resolve(nil)
  end
end
