require "test_helper"

class Assistant::Function::DeleteTaxonomyTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "deletes a family tag" do
    tag = @family.tags.create!(name: "Temporary MCP tag", color: "#e99537")

    result = Assistant::Function::DeleteTag.new(@user).call("id" => tag.id)

    assert_equal true, result[:success]
    assert_equal tag.id, result[:deleted_tag_id]
    assert_not Tag.exists?(tag.id)
  end

  test "deletes a family category" do
    category = @family.categories.create!(name: "Temporary MCP category", color: "#e99537", lucide_icon: "tag")

    result = Assistant::Function::DeleteCategory.new(@user).call("id" => category.id)

    assert_equal true, result[:success]
    assert_equal category.id, result[:deleted_category_id]
    assert_not Category.exists?(category.id)
  end

  test "reassigns transactions when replacement ids are provided" do
    transaction = transactions(:one)
    old_category = @family.categories.create!(name: "Old MCP category", color: "#e99537", lucide_icon: "tag")
    new_category = @family.categories.create!(name: "New MCP category", color: "#4da568", lucide_icon: "tag")
    old_tag = @family.tags.create!(name: "Old MCP tag", color: "#e99537")
    new_tag = @family.tags.create!(name: "New MCP tag", color: "#4da568")
    transaction.update!(category: old_category)
    transaction.tags << old_tag

    category_result = Assistant::Function::DeleteCategory.new(@user).call(
      "id" => old_category.id,
      "replacement_category_id" => new_category.id
    )
    tag_result = Assistant::Function::DeleteTag.new(@user).call(
      "id" => old_tag.id,
      "replacement_tag_id" => new_tag.id
    )

    assert_equal true, category_result[:success]
    assert_equal true, tag_result[:success]
    assert_equal new_category, transaction.reload.category
    assert_includes transaction.tags.reload, new_tag
    assert_not_includes transaction.tags, old_tag
  end

  test "does not delete another family's taxonomy" do
    other_family = families(:empty)
    tag = other_family.tags.create!(name: "Foreign tag", color: "#e99537")
    category = other_family.categories.create!(name: "Foreign category", color: "#e99537", lucide_icon: "tag")

    tag_result = Assistant::Function::DeleteTag.new(@user).call("id" => tag.id)
    category_result = Assistant::Function::DeleteCategory.new(@user).call("id" => category.id)

    assert_equal "not_found", tag_result[:error]
    assert_equal "not_found", category_result[:error]
    assert Tag.exists?(tag.id)
    assert Category.exists?(category.id)
  end
end
