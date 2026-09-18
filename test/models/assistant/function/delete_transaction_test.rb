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

  test "does not let a user from a different family delete a transaction" do
    # josh belongs to the `empty` family; the transaction belongs to
    # `dylan_family`. Cross-family ids are structurally unresolvable and must
    # not leak existence.
    function = Assistant::Function::DeleteTransaction.new(users(:josh))

    result = function.call("id" => @transaction.id)

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
    assert Transaction.exists?(@transaction.id)
  end

  test "rejects deleting a split child transaction" do
    Entry.any_instance.stubs(:split_child?).returns(true)

    result = @function.call("id" => @transaction.id)

    assert_equal false, result[:success]
    assert_equal "split_child", result[:error]
    assert Transaction.exists?(@transaction.id)
  end

  test "returns delete_aborted when a before_destroy guard aborts the destroy" do
    Entry.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed)

    result = @function.call("id" => @transaction.id)

    assert_equal false, result[:success]
    assert_equal "delete_aborted", result[:error]
    assert Transaction.exists?(@transaction.id)
  end

  test "reports deleted with a warning when the post-delete sync fails to enqueue" do
    # The transaction is already destroyed by the time sync_account_later runs,
    # so an enqueue failure must not be reported as a failed deletion.
    Entry.any_instance.stubs(:destroy!)
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "job backend unavailable")

    result = @function.call("id" => @transaction.id)

    assert_equal true, result[:success]
    assert_equal true, result[:deleted]
    assert_match(/could not be enqueued/, result[:warning])
  end
end
