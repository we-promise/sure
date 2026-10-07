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

  test "offers a rule prompt when the chosen category's existing rule does not cover this transaction" do
    category = categories(:income)
    @entry.update!(name: "AMZN Mktp UK")
    rule = @entry.account.family.rules.build(name: "Amazon", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "AMAZON.CO.UK")
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_response :success
    # The prompt is rendered into the turbo-stream response (flash is cleared once rendered).
    assert_match %r{/rules/new\?[^"]*action_value=#{category.id}}, response.body
  end

  test "does not offer a rule prompt when an existing rule already covers this transaction" do
    category = categories(:income)
    @entry.update!(name: "AMZN Mktp UK")
    rule = @entry.account.family.rules.build(name: "Amazon", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "AMZN")
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_response :success
    assert_not_includes response.body, "action_type=set_transaction_category"
  end

  test "does not offer guests to create a rule they cannot save" do
    @entry.account.update!(owner: family_guest)
    sign_in family_guest

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: categories(:income).id } } }

    assert_equal categories(:income).id, @transaction.reload.category_id
    assert_nil flash[:cta]
  end
end
