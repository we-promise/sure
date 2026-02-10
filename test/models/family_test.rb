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

  test "investment_contributions_category uses family locale consistently" do
    family = families(:dylan_family)
    family.update!(locale: "fr")
    family.categories.where(name: [ "Investment Contributions", "Contributions aux investissements" ]).destroy_all

    # Simulate different request locales (e.g., from Accept-Language header)
    # The category should always be created with the family's locale (French)
    category_from_english_request = I18n.with_locale(:en) do
      family.investment_contributions_category
    end

    assert_equal "Contributions aux investissements", category_from_english_request.name

    # Second request with different locale should find the same category
    assert_no_difference "Category.count" do
      category_from_dutch_request = I18n.with_locale(:nl) do
        family.investment_contributions_category
      end

      assert_equal category_from_english_request.id, category_from_dutch_request.id
      assert_equal "Contributions aux investissements", category_from_dutch_request.name
    end
  end

  test "investment_contributions_category prevents duplicate categories across locales" do
    family = families(:dylan_family)
    family.update!(locale: "en")
    family.categories.where(name: [ "Investment Contributions", "Contributions aux investissements" ]).destroy_all

    # Create category under English family locale
    english_category = family.investment_contributions_category
    assert_equal "Investment Contributions", english_category.name

    # Simulate a request with French locale (e.g., from browser Accept-Language)
    # Should still return the English category, not create a French one
    assert_no_difference "Category.count" do
      I18n.with_locale(:fr) do
        french_request_category = family.investment_contributions_category
        assert_equal english_category.id, french_request_category.id
        assert_equal "Investment Contributions", french_request_category.name
      end
    end
  end

  test "investment_contributions_category reuses legacy category with wrong locale" do
    family = families(:dylan_family)
    family.update!(locale: "fr")
    family.categories.where(name: [ "Investment Contributions", "Contributions aux investissements" ]).destroy_all

    # Simulate legacy: category was created with English name (old bug behavior)
    legacy_category = family.categories.create!(
      name: "Investment Contributions",
      color: "#0d9488",
      classification: "expense",
      lucide_icon: "trending-up"
    )

    # Should find and reuse the legacy category, updating its name to French
    assert_no_difference "Category.count" do
      result = family.investment_contributions_category
      assert_equal legacy_category.id, result.id
      assert_equal "Contributions aux investissements", result.name
    end
  end

  test "available_merchants includes family merchants without transactions" do
    family = families(:dylan_family)

    new_merchant = family.merchants.create!(name: "New Test Merchant")

    assert_includes family.available_merchants, new_merchant
  end
end
