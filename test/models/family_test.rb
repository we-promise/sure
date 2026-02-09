require "test_helper"

class FamilyTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  def setup
    @syncable = families(:dylan_family)
  end

  test "investment_contributions_category creates category when missing" do
    family = families(:dylan_family)
    family.categories.where(name: Category.investment_contributions_name).destroy_all

    assert_nil family.categories.find_by(name: Category.investment_contributions_name)

    category = family.investment_contributions_category

    assert category.persisted?
    assert_equal Category.investment_contributions_name, category.name
    assert_equal "#0d9488", category.color
    assert_equal "expense", category.classification
    assert_equal "trending-up", category.lucide_icon
  end

  test "investment_contributions_category returns existing category" do
    family = families(:dylan_family)
    existing = family.categories.find_or_create_by!(name: Category.investment_contributions_name) do |c|
      c.color = "#0d9488"
      c.classification = "expense"
      c.lucide_icon = "trending-up"
    end

    assert_no_difference "Category.count" do
      result = family.investment_contributions_category
      assert_equal existing, result
    end
  end

  test "available_merchants includes family merchants without transactions" do
    family = families(:dylan_family)

    new_merchant = family.merchants.create!(name: "New Test Merchant")

    assert_includes family.available_merchants, new_merchant
  end
end
