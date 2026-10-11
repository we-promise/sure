require "test_helper"

class Assistant::Function::UpdateCategoryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @category = categories(:food_and_drink)
    @fn = Assistant::Function::UpdateCategory.new(@user)
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "update_category", definition[:name]
    assert_not_empty definition[:description]
    assert_includes definition[:params_schema][:required], "id"
  end

  test "updates category name" do
    result = @fn.call("id" => @category.id, "name" => "Food & Beverages")

    assert result[:success]
    assert_equal "Food & Beverages", result[:category][:name]
    assert_equal "Food & Beverages", @category.reload.name
  end

  test "updates category color" do
    result = @fn.call("id" => @category.id, "color" => "#6471eb")

    assert result[:success]
    assert_equal "#6471eb", result[:category][:color]
    assert_equal "#6471eb", @category.reload.color
  end

  test "updates category icon" do
    result = @fn.call("id" => @category.id, "icon" => "pizza")

    assert result[:success]
    assert_equal "pizza", result[:category][:icon]
    assert_equal "pizza", @category.reload.lucide_icon
  end

  test "updates multiple fields at once" do
    result = @fn.call("id" => @category.id, "name" => "Dining", "color" => "#db5a54", "icon" => "utensils")

    assert result[:success]
    @category.reload
    assert_equal "Dining", @category.name
    assert_equal "#db5a54", @category.color
    assert_equal "utensils", @category.lucide_icon
  end

  test "result includes name_with_parent for subcategory" do
    sub = categories(:subcategory)
    result = @fn.call("id" => sub.id, "icon" => "coffee")

    assert result[:success]
    assert_match(/#{sub.parent.name}/, result[:category][:name_with_parent])
  end

  test "soft error when id is nil" do
    result = @fn.call("name" => "X")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "whitespace-only name is treated as absent, returns no_changes" do
    result = @fn.call("id" => @category.id, "name" => "   ")

    assert_equal false, result[:success]
    assert_equal "no_changes", result[:error]
  end

  test "soft error when color format is invalid" do
    result = @fn.call("id" => @category.id, "color" => "not-a-color")

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "soft error when category not found" do
    result = @fn.call("id" => "00000000-0000-0000-0000-000000000000", "name" => "X")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "soft error when no changes provided" do
    result = @fn.call("id" => @category.id)

    assert_equal false, result[:success]
    assert_equal "no_changes", result[:error]
  end

  test "cannot update a category from another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_cat = other_family.categories.create!(name: "Foreign", color: "#e99537", lucide_icon: "shapes")

    result = @fn.call("id" => other_cat.id, "name" => "Hijacked")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "moves a category under a new parent and inherits its color" do
    parent = categories(:income)

    result = @fn.call("id" => categories(:one).id, "parent_id" => parent.id)

    assert result[:success]
    assert_equal parent.id, result[:category][:parent_id]
    assert_equal parent.color, categories(:one).reload.color
  end

  test "empty parent_id promotes a subcategory to top-level" do
    sub = categories(:subcategory)

    result = @fn.call("id" => sub.id, "parent_id" => "")

    assert result[:success]
    assert_nil sub.reload.parent_id
  end

  test "soft error when moving a category with subcategories under a parent" do
    result = @fn.call("id" => @category.id, "parent_id" => categories(:income).id)

    assert_equal "validation_failed", result[:error]
    assert_nil @category.reload.parent_id
  end

  test "soft error when parent is the category itself" do
    result = @fn.call("id" => @category.id, "parent_id" => @category.id)

    assert_equal "invalid_parent", result[:error]
  end

  test "soft error when parent not found" do
    result = @fn.call("id" => @category.id, "parent_id" => "00000000-0000-0000-0000-000000000000")

    assert_equal "parent_not_found", result[:error]
  end
end
