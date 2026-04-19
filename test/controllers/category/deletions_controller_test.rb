require "test_helper"

class Category::DeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @category = categories(:food_and_drink)
    ensure_tailwind_build
  end

  test "new" do
    get new_category_deletion_url(@category)
    assert_response :success
    assert_select "turbo-frame#modal"
    assert_select "turbo-frame#modal button span.min-w-0.truncate", text: /Delete "Food & Drink" and leave uncategorized/
  end

  test "create with replacement" do
    replacement_category = categories(:income)

    assert_not_empty @category.transactions

    assert_difference "Category.count", -1 do
      assert_difference "replacement_category.transactions.count", @category.transactions.count do
        post category_deletions_url(@category),
          params: { replacement_category_id: replacement_category.id }
      end
    end

    assert_redirected_to transactions_url
  end

  test "create without replacement" do
    assert_not_empty @category.transactions

    assert_difference "Category.count", -1 do
      assert_difference "Transaction.where(category: nil).count", @category.transactions.count do
        post category_deletions_url(@category)
      end
    end

    assert_redirected_to transactions_url
  end
end
