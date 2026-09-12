require "test_helper"

class Assistant::Function::DeleteTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::DeleteTransaction.new(@user)
  end

  test "deletes a transaction and its ledger entry" do
    entry_id = @transaction.entry.id

    result = @function.call("id" => @transaction.id)

    assert_equal true, result[:success]
    assert_equal true, result[:deleted]
    assert_equal @transaction.id, result[:transaction][:id]
    assert_equal entry_id, result[:transaction][:entry_id]

    # The transaction and its root entry are both gone.
    assert_nil Transaction.find_by(id: @transaction.id)
    assert_nil Entry.find_by(id: entry_id)
  end

  test "returns not_found for an unknown id" do
    result = @function.call("id" => "00000000-0000-0000-0000-000000000000")

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
  end

  test "returns not_found when the account_id guard does not match" do
    other_account = accounts(:other_asset)

    result = @function.call("id" => @transaction.id, "account_id" => other_account.id)

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]

    # The guard mismatched, so nothing was deleted.
    assert Transaction.exists?(@transaction.id)
  end

  test "does not let read-only collaborators delete transactions" do
    transaction = transactions(:transfer_in)
    function = Assistant::Function::DeleteTransaction.new(users(:family_member))

    result = function.call("id" => transaction.id)

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
    assert Transaction.exists?(transaction.id)
  end
end
