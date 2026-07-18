require "test_helper"

class Assistant::Function::UpdateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::UpdateTransaction.new(@user)
  end

  test "updates category notes and tags" do
    category = categories(:subcategory)
    tag = tags(:one)

    result = @function.call(
      "id" => @transaction.id,
      "category_id" => category.id,
      "notes" => "Updated by assistant",
      "tag_ids" => [ tag.id ]
    )

    assert_equal true, result[:success]

    @transaction.reload
    assert_equal category, @transaction.category
    assert_equal "Updated by assistant", @transaction.entry.notes
    assert_equal [ tag.id ], @transaction.tag_ids
  end

  test "clears category merchant notes and tags when explicitly requested" do
    @transaction.update!(category: categories(:food_and_drink), merchant: merchants(:amazon))
    @transaction.tags = [ tags(:one) ]

    result = @function.call(
      "id" => @transaction.id,
      "category_id" => nil,
      "merchant_id" => nil,
      "notes" => nil,
      "tag_ids" => []
    )

    assert_equal true, result[:success]

    @transaction.reload
    assert_nil @transaction.category
    assert_nil @transaction.merchant
    assert_nil @transaction.entry.notes
    assert_empty @transaction.tags
  end

  test "rejects categories outside the family" do
    other_category = Category.create!(
      family: families(:empty),
      name: "Other",
      color: "#e99537",
      lucide_icon: "tag"
    )

    result = @function.call(
      "id" => @transaction.id,
      "category_id" => other_category.id
    )

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
  end

  test "get_transactions returns ids needed by update_transaction" do
    @transaction.entry.update!(notes: "Visible note")

    result = Assistant::Function::GetTransactions.new(@user).call(
      "page" => 1,
      "order" => "asc",
      "search" => @transaction.entry.name
    )

    transaction = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_not_nil transaction
    assert_equal @transaction.entry.notes, transaction[:notes]
  end
end
