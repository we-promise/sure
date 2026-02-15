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

  test "investment_contributions_category merges multiple locale variants" do
    family = families(:dylan_family)
    family.update!(locale: "en")
    family.categories.where(name: [ "Investment Contributions", "Contributions aux investissements" ]).destroy_all

    # Simulate legacy: multiple categories created under different locales
    english_category = family.categories.create!(
      name: "Investment Contributions",
      color: "#0d9488",
      classification: "expense",
      lucide_icon: "trending-up"
    )

    french_category = family.categories.create!(
      name: "Contributions aux investissements",
      color: "#0d9488",
      classification: "expense",
      lucide_icon: "trending-up"
    )

    # Create transactions pointing to both categories
    account = family.accounts.first
    txn1 = Transaction.create!(category: english_category)
    Entry.create!(
      account: account,
      entryable: txn1,
      amount: 100,
      currency: "USD",
      date: Date.current,
      name: "Test 1"
    )

    txn2 = Transaction.create!(category: french_category)
    Entry.create!(
      account: account,
      entryable: txn2,
      amount: 200,
      currency: "USD",
      date: Date.current,
      name: "Test 2"
    )

    # Should merge both categories into one, keeping the oldest
    assert_difference "Category.count", -1 do
      result = family.investment_contributions_category
      assert_equal english_category.id, result.id
      assert_equal "Investment Contributions", result.name

      # Both transactions should now point to the keeper
      assert_equal english_category.id, txn1.reload.category_id
      assert_equal english_category.id, txn2.reload.category_id

      # French category should be deleted
      assert_nil Category.find_by(id: french_category.id)
    end
  end

  test "moniker helpers return expected singular and plural labels" do
    family = families(:dylan_family)

    family.update!(moniker: "Family")
    assert_equal "Family", family.moniker_label
    assert_equal "Families", family.moniker_label_plural

    family.update!(moniker: "Group")
    assert_equal "Group", family.moniker_label
    assert_equal "Groups", family.moniker_label_plural
  end

  test "available_merchants includes family merchants without transactions" do
    family = families(:dylan_family)

    new_merchant = family.merchants.create!(name: "New Test Merchant")

    assert_includes family.available_merchants, new_merchant
  end

  test "upload_document stores provided metadata on family document" do
    family = families(:dylan_family)
    family.update!(vector_store_id: nil)

    adapter = mock("vector_store_adapter")
    adapter.expects(:create_store).with(name: "Family #{family.id} Documents").returns(
      VectorStore::Response.new(success?: true, data: { id: "vs_test123" }, error: nil)
    )
    adapter.expects(:upload_file).with(
      store_id: "vs_test123",
      file_content: "hello",
      filename: "notes.txt"
    ).returns(
      VectorStore::Response.new(success?: true, data: { file_id: "file-xyz" }, error: nil)
    )

    VectorStore::Registry.stubs(:adapter).returns(adapter)

    document = family.upload_document(
      file_content: "hello",
      filename: "notes.txt",
      metadata: { "type" => "financial_document" }
    )

    assert_not_nil document
    assert_equal({ "type" => "financial_document" }, document.metadata)
    assert_equal "vs_test123", family.reload.vector_store_id
  end
end
