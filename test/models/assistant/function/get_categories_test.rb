require "test_helper"

class Assistant::Function::GetCategoriesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetCategories.new(@user)
  end

  test "to_definition returns correct name and description" do
    definition = @fn.to_definition
    assert_equal "get_categories", definition[:name]
    assert_not_empty definition[:description]
  end

  test "returns all family categories" do
    result = @fn.call

    assert_kind_of Array, result[:categories]
    assert_equal @family.categories.count, result[:total]
  end

  test "each category includes required fields" do
    result = @fn.call
    result[:categories].each do |c|
      assert c[:id].present?
      assert c[:name].present?
      assert c[:name_with_parent].present?
      assert c[:color].present?
      assert c[:icon].present?
      assert c.key?(:parent_id)
      assert c.key?(:is_subcategory)
    end
  end

  test "subcategory is_subcategory is true and has parent_id" do
    result = @fn.call
    sub = result[:categories].find { |c| c[:name] == categories(:subcategory).name }

    assert sub.present?
    assert sub[:is_subcategory]
    assert_equal categories(:food_and_drink).id, sub[:parent_id]
  end

  test "top-level category has nil parent_id and is_subcategory false" do
    result = @fn.call
    top = result[:categories].find { |c| c[:name] == categories(:food_and_drink).name }

    assert top.present?
    assert_not top[:is_subcategory]
    assert_nil top[:parent_id]
  end

  test "scopes to the user's family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_family.categories.create!(name: "Foreign Category", color: "#e99537", lucide_icon: "shapes")

    result = @fn.call
    category_names = result[:categories].map { |c| c[:name] }
    assert_not_includes category_names, "Foreign Category"
  end
end
