require "test_helper"

class Assistant::Function::CreateCategoryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateCategory.new(@user)
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "create_category", definition[:name]
    assert_not_empty definition[:description]
    assert_includes definition[:params_schema][:required], "name"
  end

  test "creates a top-level category with all fields" do
    assert_difference "@family.categories.count" do
      result = @fn.call("name" => "Transport", "color" => "#4da568", "icon" => "bus")

      assert result[:success]
      assert_equal "Transport", result[:category][:name]
      assert_equal "#4da568", result[:category][:color]
      assert_equal "bus", result[:category][:icon]
      assert_nil result[:category][:parent_id]
    end
  end

  test "auto-suggests icon from name when omitted" do
    result = @fn.call("name" => "Groceries", "color" => "#4da568")

    assert result[:success]
    assert_equal Category.suggested_icon("Groceries"), result[:category][:icon]
  end

  test "auto-assigns color from palette when omitted" do
    result = @fn.call("name" => "Mystery")

    assert result[:success]
    assert_includes Category::COLORS, result[:category][:color]
  end

  test "creates a subcategory under an existing parent" do
    parent = categories(:food_and_drink)
    assert_difference "@family.categories.count" do
      result = @fn.call("name" => "Fast Food", "parent_id" => parent.id)

      assert result[:success]
      assert_equal parent.id, result[:category][:parent_id]
      assert_match "Food & Drink > Fast Food", result[:category][:name_with_parent]
    end
  end

  test "subcategory inherits parent color" do
    parent = categories(:food_and_drink)
    result = @fn.call("name" => "Sushi", "parent_id" => parent.id)

    assert result[:success]
    assert_equal parent.reload.color, result[:category][:color]
  end

  test "soft error when name is whitespace only" do
    result = @fn.call("name" => "   ")

    assert_equal false, result[:success]
    assert_equal "name_required", result[:error]
  end

  test "empty string parent_id is treated as absent, creates top-level category" do
    assert_difference "@family.categories.count" do
      result = @fn.call("name" => "No Parent", "parent_id" => "")

      assert result[:success]
      assert_nil result[:category][:parent_id]
    end
  end

  test "soft error when color format is invalid" do
    result = @fn.call("name" => "Bad Color Cat", "color" => "not-a-color")

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "soft error when nesting a subcategory under another subcategory" do
    sub = categories(:subcategory)
    result = @fn.call("name" => "Too Deep", "parent_id" => sub.id)

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "soft error when name is blank" do
    result = @fn.call("name" => "")

    assert_equal false, result[:success]
    assert_equal "name_required", result[:error]
  end

  test "soft error when parent_id does not exist" do
    result = @fn.call("name" => "Orphan", "parent_id" => "00000000-0000-0000-0000-000000000000")

    assert_equal false, result[:success]
    assert_equal "parent_not_found", result[:error]
  end

  test "soft error on duplicate name within family" do
    existing = categories(:food_and_drink)
    result = @fn.call("name" => existing.name)

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
  end

  test "cannot use a parent from another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_parent = other_family.categories.create!(name: "Foreign Parent", color: "#e99537", lucide_icon: "shapes")

    result = @fn.call("name" => "Child", "parent_id" => other_parent.id)

    assert_equal false, result[:success]
    assert_equal "parent_not_found", result[:error]
  end
end
