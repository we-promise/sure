require "test_helper"

class Assistant::Function::DeleteCategoryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @category = categories(:food_and_drink)
    @fn = Assistant::Function::DeleteCategory.new(@user)
  end

  test "deletes category and uncategorizes its transactions" do
    transaction = transactions(:one)
    assert_equal @category, transaction.category

    result = @fn.call("id" => @category.id)

    assert result[:success]
    assert_not Category.exists?(@category.id)
    assert_nil transaction.reload.category_id
  end

  test "moves transactions to the replacement category" do
    transaction = transactions(:one)
    replacement = categories(:income)

    result = @fn.call("id" => @category.id, "replacement_id" => replacement.id)

    assert result[:success]
    assert_equal replacement.id, result[:replacement_id]
    assert_equal replacement, transaction.reload.category
  end

  test "promotes subcategories of a deleted parent to top-level" do
    sub = categories(:subcategory)

    @fn.call("id" => @category.id)

    assert_nil sub.reload.parent_id
  end

  test "soft error when category not found" do
    result = @fn.call("id" => "00000000-0000-0000-0000-000000000000")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "soft error when replacement is the category itself" do
    result = @fn.call("id" => @category.id, "replacement_id" => @category.id)

    assert_equal "invalid_replacement", result[:error]
    assert Category.exists?(@category.id)
  end

  test "cannot delete or replace with a category from another family" do
    other_family = Family.create!(name: "Other", currency: "USD", locale: "en", country: "US", timezone: "UTC")
    other_cat = other_family.categories.create!(name: "Foreign", color: "#e99537", lucide_icon: "shapes")

    assert_equal "not_found", @fn.call("id" => other_cat.id)[:error]
    assert_equal "replacement_not_found", @fn.call("id" => @category.id, "replacement_id" => other_cat.id)[:error]
    assert Category.exists?(other_cat.id)
    assert Category.exists?(@category.id)
  end

  test "guests cannot delete categories" do
    @user.stubs(:guest?).returns(true)

    result = @fn.call("id" => @category.id)

    assert_equal "forbidden", result[:error]
    assert Category.exists?(@category.id)
  end
end
