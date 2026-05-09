require "test_helper"

class Provider::Plaid::Transactions::CategoryTaxonomyTest < ActiveSupport::TestCase
  test "resolves a known detailed key" do
    result = Provider::Plaid::Transactions::CategoryTaxonomy.resolve("food_and_drink_restaurant")
    assert_equal [ "restaurant", "dining" ], result[:aliases]
    assert_equal [ "food", "dining", "food and drink", "food & drink" ], result[:parent_aliases]
    assert_equal %i[aliases parent_aliases].sort, result.keys.sort
  end

  test "is case-insensitive" do
    result = Provider::Plaid::Transactions::CategoryTaxonomy.resolve("FOOD_AND_DRINK_RESTAURANT")
    assert_equal [ "restaurant", "dining" ], result[:aliases]
  end

  test "returns nil for unknown key" do
    assert_nil Provider::Plaid::Transactions::CategoryTaxonomy.resolve("not_a_real_key")
  end

  test "returns nil for blank input" do
    assert_nil Provider::Plaid::Transactions::CategoryTaxonomy.resolve(nil)
    assert_nil Provider::Plaid::Transactions::CategoryTaxonomy.resolve("")
  end
end
