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
