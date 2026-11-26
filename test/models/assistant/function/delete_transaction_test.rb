require "test_helper"

class Assistant::Function::DeleteTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include PreviewTokenTestHelper

  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::DeleteTransaction.new(@user)
  end

  test "without a preview_token it previews the deletion and deletes nothing" do
    entry = @transaction.entry

    result = @function.call("id" => @transaction.id)

    assert_equal true, result[:success]
    assert_equal false, result[:deleted]
    assert_equal @transaction.id, result[:preview][:id]
    assert_equal entry.id, result[:preview][:entry_id]
    assert_equal entry.account.name, result[:preview][:account]
    assert_equal entry.amount.to_s, result[:preview][:amount]
    assert result[:preview_token].present?
    assert Transaction.exists?(@transaction.id)
    assert Entry.exists?(entry.id)
  end

  test "deletes a transaction and its ledger entry with the token from its preview" do
    entry_id = @transaction.entry.id

    result = delete_with_preview(@function, "id" => @transaction.id)

    assert_equal true, result[:success]
    assert_equal true, result[:deleted]
    assert_equal @transaction.id, result[:transaction][:id]
    assert_equal entry_id, result[:transaction][:entry_id]

    # The transaction and its root entry are both gone.
    assert_nil Transaction.find_by(id: @transaction.id)
    assert_nil Entry.find_by(id: entry_id)
  end

  test "refuses a forged token, another transaction's token and another tool's token" do
    other = transactions(:transfer_out)
    other_token = @function.call("id" => other.id)[:preview_token]
    assert other_token.present?

    category_token = Assistant::Function::DeleteCategory.new(@user).call("id" => categories(:food_and_drink).id)[:preview_token]
    assert category_token.present?

    [ "forged", other_token, category_token ].each do |token|
      result = @function.call("id" => @transaction.id, "preview_token" => token)

      assert_equal false, result[:success]
      assert_equal "preview_required", result[:error]
    end
    assert Transaction.exists?(@transaction.id)
  end

  test "refuses a token issued to another user, including one from another family" do
    member_token = Assistant::Function::DeleteTransaction.new(users(:family_member)).call("id" => @transaction.id)[:preview_token]
    assert member_token.present?, "family_member has full control of the account, so its preview issues a token"

    josh = users(:josh)
    foreign_account = josh.family.accounts.create!(
      name: "Foreign checking", balance: 0, currency: "USD", accountable: Depository.new, owner: josh
    )
    foreign = create_transaction(account: foreign_account, name: "Foreign").entryable
    foreign_token = Assistant::Function::DeleteTransaction.new(josh).call("id" => foreign.id)[:preview_token]
    assert foreign_token.present?

    [ member_token, foreign_token ].each do |token|
      assert_equal "preview_required", @function.call("id" => @transaction.id, "preview_token" => token)[:error]
    end
    assert_equal "not_found", @function.call("id" => foreign.id, "preview_token" => foreign_token)[:error]
    assert Transaction.exists?(@transaction.id)
    assert Transaction.exists?(foreign.id)
  end

  test "refuses an expired token" do
    token = @function.call("id" => @transaction.id)[:preview_token]

    travel Assistant::Function::PreviewToken::PREVIEW_TOKEN_TTL + 1.minute do
      assert_equal "preview_required", @function.call("id" => @transaction.id, "preview_token" => token)[:error]
    end
    assert Transaction.exists?(@transaction.id)
  end

  test "refuses a token once the transaction changed, and returns a fresh preview" do
    token = @function.call("id" => @transaction.id)[:preview_token]
    @transaction.entry.update!(amount: @transaction.entry.amount + 100)

    result = @function.call("id" => @transaction.id, "preview_token" => token)

    assert_equal false, result[:success]
    assert_equal "preview_stale", result[:error]
    assert_equal @transaction.entry.reload.amount.to_s, result[:preview][:amount]
    assert result[:preview_token].present?
    assert Transaction.exists?(@transaction.id)

    assert_equal true, @function.call("id" => @transaction.id, "preview_token" => result[:preview_token])[:deleted]
  end

  test "refuses a token once the transaction changed after the token was checked" do
    token = @function.call("id" => @transaction.id)[:preview_token]
    change_after_token_check(@function) { @transaction.entry.update!(amount: @transaction.entry.amount + 100) }

    result = @function.call("id" => @transaction.id, "preview_token" => token)

    assert_equal "preview_stale", result[:error]
    assert Transaction.exists?(@transaction.id)
  end

  test "a split parent's preview lists its children, and a token is refused once it was split again" do
    entry = create_transaction(amount: 100, name: "Grocery Store", account: accounts(:depository))
    children = entry.split!([ { name: "Food", amount: 70, category_id: nil }, { name: "Home", amount: 30, category_id: nil } ])
    params = { "id" => entry.transaction.id }

    preview = @function.call(params)
    assert_equal children.map(&:id), preview[:preview][:split_children].map { |child| child[:entry_id] }
    assert_equal %w[70.0 30.0], preview[:preview][:split_children].map { |child| child[:amount] }

    entry.reload.resplit!([ { name: "Food", amount: 60, category_id: nil }, { name: "Home", amount: 40, category_id: nil } ])
    result = @function.call(params.merge("preview_token" => preview[:preview_token]))

    assert_equal "preview_stale", result[:error]
    assert_equal %w[60.0 40.0], result[:preview][:split_children].map { |child| child[:amount] }
    assert Entry.exists?(entry.id)
    assert_equal true, delete_with_preview(@function, params)[:deleted]
  end

  test "a transfer leg's preview shows the transfer and the fees it deletes, and a fee added since refuses the token" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    fee = create_transaction(account: accounts(:depository), name: "Transfer fee", amount: 2).entryable
    transfer.fee_transactions << fee
    params = { "id" => transfer.outflow_transaction.id }

    preview = @function.call(params)
    assert_equal transfer.id, preview[:preview][:transfer][:id]
    assert_equal transfer.inflow_transaction.id, preview[:preview][:transfer][:counterpart][:id]
    assert_equal [ fee.id ], preview[:preview][:transfer][:deleted_fee_transactions].map { |t| t[:id] }

    transfer.fee_transactions << create_transaction(account: accounts(:depository), name: "Late fee", amount: 3).entryable
    result = @function.call(params.merge("preview_token" => preview[:preview_token]))

    assert_equal "preview_stale", result[:error]
    assert_equal 2, result[:preview][:transfer][:deleted_fee_transactions].size
    assert Transfer.exists?(transfer.id)
  end

  test "a member's preview of a transfer leg names neither the account nor the other leg it cannot open" do
    hidden = hidden_account
    transfer = create_transfer(from_account: accounts(:depository), to_account: hidden, amount: 100)
    transfer.outflow_transaction.entry.update!(name: "Savings top-up")
    member = Assistant::Function::DeleteTransaction.new(users(:family_member))
    params = { "id" => transfer.outflow_transaction.id }

    preview = member.call(params)

    assert_equal({ account: "another account" }, preview[:preview][:transfer][:counterpart])
    assert_not_includes preview.to_json, hidden.name
    assert_not_includes preview.to_json, transfer.inflow_transaction.id

    result = member.call(params.merge("preview_token" => preview[:preview_token]))

    assert_equal true, result[:deleted]
    assert_equal "standard", transfer.inflow_transaction.reload.kind
  end

  test "rereads account access when the delete is confirmed" do
    share = accounts(:investment).account_shares.create!(user: users(:family_member), permission: "read_only")
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    transfer.outflow_transaction.entry.update!(name: "Brokerage top-up")
    member = Assistant::Function::DeleteTransaction.new(users(:family_member))
    params = { "id" => transfer.outflow_transaction.id }
    preview = member.call(params)
    assert_equal transfer.inflow_transaction.id, preview[:preview][:transfer][:counterpart][:id]

    # The same instance confirms, as in one chat response.
    change_after_token_check(member) { share.destroy! }
    result = member.call(params.merge("preview_token" => preview[:preview_token]))

    assert_equal "preview_stale", result[:error]
    assert_equal({ account: "another account" }, result[:preview][:transfer][:counterpart])
    assert_not_includes result.to_json, accounts(:investment).name
    assert Transaction.exists?(transfer.outflow_transaction.id)
  end

  test "refuses to delete a transfer leg whose fees sit on an account the user cannot write" do
    member = Assistant::Function::DeleteTransaction.new(users(:family_member))
    # family_member cannot open the hidden account and only reads the credit card.
    [ hidden_account, accounts(:credit_card) ].each do |other|
      transfer = create_transfer(from_account: accounts(:depository), to_account: other, amount: 100)
      transfer.outflow_transaction.entry.update!(name: "Card payment")
      fee = create_transaction(account: other, name: "Incoming fee", amount: 2).entryable
      transfer.fee_transactions << fee

      result = member.call("id" => transfer.outflow_transaction.id)

      assert_equal false, result[:success]
      assert_equal "transfer_spans_unwritable_account", result[:error]
      assert_nil result[:preview_token]
      assert_not_includes result.to_json, other.name
      assert Transfer.exists?(transfer.id)
      assert Transaction.exists?(fee.id)
    end
  end

  test "refuses a token once a fee on an account the user cannot write was attached, without disclosing it" do
    hidden = hidden_account
    transfer = create_transfer(from_account: accounts(:depository), to_account: hidden, amount: 100)
    transfer.outflow_transaction.entry.update!(name: "Savings top-up")
    member = Assistant::Function::DeleteTransaction.new(users(:family_member))
    params = { "id" => transfer.outflow_transaction.id }
    token = member.call(params)[:preview_token]

    change_after_token_check(member) do
      transfer.fee_transactions << create_transaction(account: hidden, name: "Hidden fee", amount: 2).entryable
    end
    stale = member.call(params.merge("preview_token" => token))

    assert_equal "preview_stale", stale[:error]
    assert_equal [ { account: "another account" } ], stale[:preview][:transfer][:deleted_fee_transactions]
    assert_not_includes stale.to_json, "Hidden fee"

    result = Assistant::Function::DeleteTransaction.new(users(:family_member)).call(params.merge("preview_token" => stale[:preview_token]))

    assert_equal "transfer_spans_unwritable_account", result[:error]
    assert Transfer.exists?(transfer.id)
  end

  test "rechecks write access to a transfer's fee accounts under the lock" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 100)
    fee = create_transaction(account: accounts(:investment), name: "Incoming fee", amount: 2).entryable
    transfer.fee_transactions << fee
    accounts(:investment).account_shares.create!(user: users(:family_member), permission: "full_control")
    member = Assistant::Function::DeleteTransaction.new(users(:family_member))
    params = { "id" => transfer.outflow_transaction.id }
    token = member.call(params)[:preview_token]
    assert token.present?

    # A downgrade to read-only leaves the preview unchanged.
    change_after_token_check(member) { accounts(:investment).account_shares.find_by!(user: users(:family_member)).update!(permission: "read_only") }
    result = member.call(params.merge("preview_token" => token))

    assert_equal "transfer_spans_unwritable_account", result[:error]
    assert Transaction.exists?(fee.id)
  end

  test "a transaction outside splits and transfers previews neither" do
    preview = @function.call("id" => @transaction.id)[:preview]

    refute preview.key?(:split_children)
    refute preview.key?(:transfer)
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

  test "does not let read-only collaborators preview or delete transactions" do
    transaction = transactions(:transfer_in)
    function = Assistant::Function::DeleteTransaction.new(users(:family_member))

    result = function.call("id" => transaction.id)

    assert_equal false, result[:success]
    assert_equal "not_found", result[:error]
    assert_nil result[:preview_token]
    assert Transaction.exists?(transaction.id)
  end

  test "does not let a guest preview or delete a transaction in an account shared read-only" do
    account = @transaction.entry.account
    account.account_shares.create!(user: family_guest, permission: "read_only")
    function = Assistant::Function::DeleteTransaction.new(family_guest)

    result = function.call("id" => @transaction.id)

    assert_equal "not_found", result[:error]
    assert_nil result[:preview_token]
    assert Transaction.exists?(@transaction.id)
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

  test "rejects previewing or deleting a split child transaction" do
    Entry.any_instance.stubs(:split_child?).returns(true)

    result = @function.call("id" => @transaction.id)

    assert_equal false, result[:success]
    assert_equal "split_child", result[:error]
    assert Transaction.exists?(@transaction.id)
  end

  test "refuses deleting a split whose part is linked as a transfer" do
    parent = create_transaction(account: accounts(:depository), amount: 100, name: "Mortgage")
    part = parent.split!([ { name: "Principal", amount: 60 }, { name: "Interest", amount: 40 } ]).first
    transfer = link_split_part_to_loan(part)

    result = @function.call("id" => parent.transaction.id)

    assert_equal false, result[:success]
    assert_equal "split_part_transferred", result[:error]
    assert Entry.exists?(parent.id)
    assert Transfer.exists?(transfer.id)
  end

  test "refuses confirming a split delete when a part is linked as a transfer between the check and the lock" do
    parent = create_transaction(account: accounts(:depository), amount: 100, name: "Mortgage")
    part = parent.split!([ { name: "Principal", amount: 60 }, { name: "Interest", amount: 40 } ]).first
    token = @function.call("id" => parent.transaction.id)[:preview_token]
    transfer = link_split_part_to_loan(part)
    # The unlocked check runs first and misses the transfer; the one under the split lock sees it.
    Entry.any_instance.stubs(:split_part_transferred?).returns(false).then.returns(true)

    result = @function.call("id" => parent.transaction.id, "preview_token" => token)

    assert_equal false, result[:success]
    assert_equal "split_part_transferred", result[:error]
    assert Entry.exists?(parent.id)
    assert Transfer.exists?(transfer.id)
  end

  test "returns delete_aborted when a before_destroy guard aborts the destroy" do
    token = @function.call("id" => @transaction.id)[:preview_token]
    Entry.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed)

    result = @function.call("id" => @transaction.id, "preview_token" => token)

    assert_equal false, result[:success]
    assert_equal "delete_aborted", result[:error]
    assert Transaction.exists?(@transaction.id)
  end

  test "reports deleted with a warning when the post-delete sync fails to enqueue" do
    # The transaction is already destroyed by the time sync_account_later runs,
    # so an enqueue failure must not be reported as a failed deletion.
    token = @function.call("id" => @transaction.id)[:preview_token]
    Entry.any_instance.stubs(:destroy!)
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "job backend unavailable")

    result = @function.call("id" => @transaction.id, "preview_token" => token)

    assert_equal true, result[:success]
    assert_equal true, result[:deleted]
    assert_match(/could not be enqueued/, result[:warning])
  end

  private
    def hidden_account
      users(:family_admin).family.accounts.create!(
        name: "Hidden Savings", balance: 0, currency: "USD", accountable: Depository.new, owner: users(:family_admin)
      )
    end

    def delete_with_preview(function, params)
      token = function.call(params)[:preview_token]
      assert token.present?, "the preview issued no token"
      function.call(params.merge("preview_token" => token))
    end
end
