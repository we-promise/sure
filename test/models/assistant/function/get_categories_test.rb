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
    assert_equal "object", definition[:params_schema][:type]
  end

  test "returns paginated categories" do
    result = @fn.call({ "page" => 1 })

    assert_kind_of Array, result[:categories]
    assert_equal 1, result[:page]
    assert result[:total_results] >= result[:categories].size
    assert result[:total_pages] >= 1
    assert_equal Assistant::Function::GetCategories.default_page_size, result[:page_size]
  end

  test "each category includes required fields" do
    result = @fn.call({ "page" => 1 })
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
    result = @fn.call({ "page" => 1 })
    sub = result[:categories].find { |c| c[:name] == categories(:subcategory).name }

    assert sub.present?
    assert sub[:is_subcategory]
    assert_equal categories(:food_and_drink).id, sub[:parent_id]
  end

  test "top-level category has nil parent_id and is_subcategory false" do
    result = @fn.call({ "page" => 1 })
    top = result[:categories].find { |c| c[:name] == categories(:food_and_drink).name }

    assert top.present?
    assert_not top[:is_subcategory]
    assert_nil top[:parent_id]
  end

  test "scopes to the user's family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_family.categories.create!(name: "Foreign Category", color: "#e99537", lucide_icon: "shapes")

    result = @fn.call({ "page" => 1 })
    category_names = result[:categories].map { |c| c[:name] }
    assert_not_includes category_names, "Foreign Category"
  end

  test "defaults to page 1 when page param is omitted" do
    result_with_page = @fn.call({ "page" => 1 })
    result_without_page = @fn.call

    assert_equal result_with_page[:page], result_without_page[:page]
    assert_equal result_with_page[:total_results], result_without_page[:total_results]
  end

  test "paginates correctly when there are multiple pages" do
    50.times { |i| @family.categories.create!(name: "PaginationCategory#{format('%02d', i)}", color: "#e99537", lucide_icon: "shapes") }

    page1 = @fn.call({ "page" => 1 })
    page2 = @fn.call({ "page" => 2 })

    assert page1[:total_pages] > 1
    assert_equal 1, page1[:page]
    assert_equal 2, page2[:page]
    assert_not_equal page1[:categories].map { |c| c[:name] }, page2[:categories].map { |c| c[:name] }
  end
end
