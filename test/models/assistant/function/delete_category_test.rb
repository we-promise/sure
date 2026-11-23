require "test_helper"

class Assistant::Function::DeleteCategoryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @category = categories(:food_and_drink)
    @fn = Assistant::Function::DeleteCategory.new(@user)
  end

  test "without a preview_token it previews the deletion and deletes nothing" do
    transaction = transactions(:one)
    replacement = categories(:income)

    result = @fn.call("id" => @category.id, "replacement_id" => replacement.id)

    assert_equal true, result[:success]
    assert_equal false, result[:deleted]
    assert_equal @category.name, result[:preview][:category][:name]
    assert_equal @category.transactions.count, result[:preview][:transaction_count]
    assert_equal replacement.name, result[:preview][:replacement][:name]
    assert_includes result[:preview][:subcategories], categories(:subcategory).name
    assert result[:preview_token].present?
    assert Category.exists?(@category.id)
    assert_equal @category, transaction.reload.category
  end

  test "deletes category and uncategorizes its transactions with the token from its preview" do
    transaction = transactions(:one)
    assert_equal @category, transaction.category

    result = delete_with_preview("id" => @category.id)

    assert result[:success]
    assert result[:deleted]
    assert_not Category.exists?(@category.id)
    assert_nil transaction.reload.category_id
  end

  test "moves transactions to the replacement category" do
    transaction = transactions(:one)
    replacement = categories(:income)

    result = delete_with_preview("id" => @category.id, "replacement_id" => replacement.id)

    assert result[:success]
    assert_equal replacement.id, result[:replacement_id]
    assert_equal replacement, transaction.reload.category
  end

  test "promotes subcategories of a deleted parent to top-level" do
    sub = categories(:subcategory)

    delete_with_preview("id" => @category.id)

    assert_nil sub.reload.parent_id
  end

  test "refuses a token previewed for another replacement" do
    token = @fn.call("id" => @category.id)[:preview_token]

    result = @fn.call("id" => @category.id, "replacement_id" => categories(:income).id, "preview_token" => token)

    assert_equal "preview_stale", result[:error]
    assert_equal categories(:income).name, result[:preview][:replacement][:name]
    assert Category.exists?(@category.id)
  end

  test "refuses a token once the category gained transactions, and returns a fresh preview" do
    token = @fn.call("id" => @category.id)[:preview_token]
    create_transaction(name: "Late arrival", category: @category)

    result = @fn.call("id" => @category.id, "preview_token" => token)

    assert_equal "preview_stale", result[:error]
    assert_equal @category.transactions.count, result[:preview][:transaction_count]
    assert Category.exists?(@category.id)
  end

  test "refuses a forged token, another category's token, another user's token and an expired one" do
    other_token = @fn.call("id" => categories(:income).id)[:preview_token]
    member_token = Assistant::Function::DeleteCategory.new(users(:family_member)).call("id" => @category.id)[:preview_token]
    transaction_token = Assistant::Function::DeleteTransaction.new(@user).call("id" => transactions(:one).id)[:preview_token]
    assert [ other_token, member_token, transaction_token ].all?(&:present?)

    [ "forged", other_token, member_token, transaction_token ].each do |token|
      assert_equal "preview_required", @fn.call("id" => @category.id, "preview_token" => token)[:error]
    end

    token = @fn.call("id" => @category.id)[:preview_token]
    travel Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL + 1.minute do
      assert_equal "preview_required", @fn.call("id" => @category.id, "preview_token" => token)[:error]
    end
    assert Category.exists?(@category.id)
  end

  test "soft error when category not found" do
    result = @fn.call("id" => "00000000-0000-0000-0000-000000000000")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "blank replacement_id is rejected instead of uncategorizing" do
    [ "", "   " ].each do |blank|
      result = @fn.call("id" => @category.id, "replacement_id" => blank)

      assert_equal "replacement_not_found", result[:error]
    end
    assert Category.exists?(@category.id)
    assert_equal @category, transactions(:one).reload.category
  end

  test "null replacement_id uncategorizes like an omitted one" do
    result = delete_with_preview("id" => @category.id, "replacement_id" => nil)

    assert result[:success]
    assert_not Category.exists?(@category.id)
    assert_nil transactions(:one).reload.category_id
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

  private
    def delete_with_preview(params)
      token = @fn.call(params)[:preview_token]
      assert token.present?, "the preview issued no token"
      @fn.call(params.merge("preview_token" => token))
    end
end
