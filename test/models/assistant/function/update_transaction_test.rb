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
    assert @transaction.locked?(:tag_ids)
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

  test "does not let read-only collaborators update transactions" do
    transaction = transactions(:transfer_in)
    function = Assistant::Function::UpdateTransaction.new(users(:family_member))

    result = function.call("id" => transaction.id, "notes" => "Should not be saved")

    assert_equal false, result[:success]
    assert_equal "not_authorized", result[:error]
    assert_nil transaction.reload.entry.notes
  end

  test "lets read-write collaborators update annotations but not names" do
    transaction = transactions(:transfer_in)
    transaction.entry.account.account_shares.find_by!(user: users(:family_member)).update!(permission: "read_write")
    function = Assistant::Function::UpdateTransaction.new(users(:family_member))

    annotation_result = function.call("id" => transaction.id, "notes" => "Shared note")
    rename_result = function.call("id" => transaction.id, "name" => "Renamed transaction")

    assert_equal true, annotation_result[:success]
    assert_equal "Shared note", transaction.reload.entry.notes
    assert_equal false, rename_result[:success]
    assert_equal "not_authorized", rename_result[:error]
    assert_equal "Payment received from checking account", transaction.reload.entry.name
  end
end
