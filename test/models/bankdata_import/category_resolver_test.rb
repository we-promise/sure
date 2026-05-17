# frozen_string_literal: true

require "test_helper"

class BankdataImport::CategoryResolverTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "creates and resolves parent child hierarchy" do
    category = BankdataImport::CategoryResolver.new(@family).resolve(parent_name: "Auto", category_name: "Benzine")

    assert_equal "Benzine", category.name
    assert_equal "Auto", category.parent.name
  end

  test "reuses existing categories" do
    parent = @family.categories.create!(name: "Auto", color: "#4da568", lucide_icon: "car")
    child = @family.categories.create!(name: "Benzine", parent: parent, color: "#4da568", lucide_icon: "fuel")

    assert_equal child, BankdataImport::CategoryResolver.new(@family).resolve(parent_name: "Auto", category_name: "Benzine")
  end

  test "creates Auto greater than Benzine hierarchy behavior" do
    category = BankdataImport::CategoryResolver.new(@family).resolve(parent_name: "Auto", category_name: "Benzine")

    assert_equal "Auto", category.parent.name
    assert_equal "Benzine", category.name
  end
end
