require "test_helper"

class TransactionCategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @entry = entries(:transaction)
    @transaction = transactions(:one)
  end

  test "assigning a category touches its last_used_at" do
    category = categories(:income)
    assert_nil category.last_used_at

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_not_nil category.reload.last_used_at
  end

  test "clearing a category does not touch any category's last_used_at" do
    category = @transaction.category
    assert_nil category.last_used_at

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: nil } } },
      as: :turbo_stream

    assert_response :success
    assert_nil @transaction.reload.category_id
    assert_nil category.reload.last_used_at
  end
end
