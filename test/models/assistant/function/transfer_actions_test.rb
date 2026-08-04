require "test_helper"

class Assistant::Function::TransferActionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @source = accounts(:depository)
    @destination = @family.accounts.create!(owner: @user, name: "MCP Savings", accountable: Depository.new(subtype: "savings"), balance: 0, currency: "USD")
  end

  test "creates lists updates and unlinks a transfer" do
    create_result = Assistant::Function::CreateTransfer.new(@user).call(
      "from_account_id" => @source.id,
      "to_account_id" => @destination.id,
      "amount" => 125,
      "date" => Date.current.iso8601,
      "external_id" => "transfer-actions-#{SecureRandom.uuid}"
    )

    assert_equal true, create_result[:success]
    transfer_id = create_result.dig(:transfer, :id)

    listed = Assistant::Function::GetTransfers.new(@user).call
    assert_includes listed[:transfers].pluck(:id), transfer_id

    update_result = Assistant::Function::UpdateTransfer.new(@user).call(
      "id" => transfer_id,
      "amount" => 150,
      "date" => (Date.current - 1.day).iso8601,
      "notes" => "Moved by MCP"
    )

    assert_equal true, update_result[:success]
    transfer = Transfer.find(transfer_id)
    assert_equal 150, transfer.outflow_transaction.entry.amount
    assert_equal(-150, transfer.inflow_transaction.entry.amount)
    assert_equal Date.current - 1.day, transfer.date
    assert_equal "Moved by MCP", transfer.notes
    assert transfer.outflow_transaction.entry.reload.user_modified?
    assert transfer.inflow_transaction.entry.reload.user_modified?
    assert transfer.outflow_transaction.entry.locked_attributes.key?("amount")
    assert transfer.inflow_transaction.entry.locked_attributes.key?("amount")

    outflow_id = transfer.outflow_transaction_id
    inflow_id = transfer.inflow_transaction_id
    delete_result = Assistant::Function::DeleteTransfer.new(@user).call("id" => transfer_id)

    assert_equal true, delete_result[:success]
    assert_not Transfer.exists?(transfer_id)
    assert Transaction.exists?(outflow_id)
    assert Transaction.exists?(inflow_id)
  end

  test "notes-only update preserves both transfer entry amounts" do
    euro_account = @family.accounts.create!(
      owner: @user,
      name: "MCP Euro Savings",
      accountable: Depository.new(subtype: "savings"),
      balance: 0,
      currency: "EUR"
    )
    created = Assistant::Function::CreateTransfer.new(@user).call(
      "from_account_id" => @source.id,
      "to_account_id" => euro_account.id,
      "amount" => 125,
      "date" => Date.current.iso8601,
      "exchange_rate" => 0.8,
      "external_id" => "transfer-notes-#{SecureRandom.uuid}"
    )
    transfer = Transfer.find(created.dig(:transfer, :id))
    original_outflow = transfer.outflow_transaction.entry.amount
    original_inflow = transfer.inflow_transaction.entry.amount

    result = Assistant::Function::UpdateTransfer.new(@user).call("id" => transfer.id, "notes" => "metadata only")

    assert_equal true, result[:success]
    assert_equal original_outflow, transfer.outflow_transaction.entry.reload.amount
    assert_equal original_inflow, transfer.inflow_transaction.entry.reload.amount
  end

  test "create is idempotent and rejects divergent reuse" do
    external_id = "transfer-idempotency-#{SecureRandom.uuid}"
    params = {
      "from_account_id" => @source.id,
      "to_account_id" => @destination.id,
      "amount" => 125,
      "date" => Date.current.iso8601,
      "external_id" => external_id
    }
    function = Assistant::Function::CreateTransfer.new(@user)

    first = function.call(params)
    repeated = function.call(params)
    conflict = function.call(params.merge("amount" => 126))

    assert_equal true, first[:created]
    assert_equal false, repeated[:created]
    assert_equal first.dig(:transfer, :id), repeated.dig(:transfer, :id)
    assert_equal false, conflict[:success]
    assert_equal "idempotency_conflict", conflict[:error]
    assert_equal 1, Transfer.where(external_id: "#{@family.id}:#{external_id}").count
  end

  test "allows the same caller idempotency key in another family" do
    external_id = "shared-caller-key-#{SecureRandom.uuid}"
    first = Assistant::Function::CreateTransfer.new(@user).call(
      "from_account_id" => @source.id,
      "to_account_id" => @destination.id,
      "amount" => 25,
      "date" => Date.current.iso8601,
      "external_id" => external_id
    )

    other_user = users(:empty)
    other_family = other_user.family
    other_source = other_family.accounts.create!(owner: other_user, name: "Other source", accountable: Depository.new, balance: 100, currency: "USD")
    other_destination = other_family.accounts.create!(owner: other_user, name: "Other destination", accountable: Depository.new, balance: 0, currency: "USD")
    second = Assistant::Function::CreateTransfer.new(other_user).call(
      "from_account_id" => other_source.id,
      "to_account_id" => other_destination.id,
      "amount" => 25,
      "date" => Date.current.iso8601,
      "external_id" => external_id
    )

    assert_equal true, first[:success]
    assert_equal true, second[:success]
    assert_not_equal first.dig(:transfer, :id), second.dig(:transfer, :id)
    assert_equal external_id, second.dig(:transfer, :external_id)
  end

  test "recovers an exact transfer after a unique-index race" do
    external_id = "transfer-race-#{SecureRandom.uuid}"
    params = {
      "from_account_id" => @source.id,
      "to_account_id" => @destination.id,
      "amount" => 125,
      "date" => Date.current.iso8601,
      "external_id" => external_id
    }
    function = Assistant::Function::CreateTransfer.new(@user)
    first = function.call(params)
    existing = Transfer.find(first.dig(:transfer, :id))
    storage_key = "#{@family.id}:#{external_id}"
    Transfer.stubs(:find_by).with(external_id: storage_key).returns(nil, existing)

    raced = function.call(params)

    assert_equal true, raced[:success]
    assert_equal false, raced[:created]
    assert_equal existing.id, raced.dig(:transfer, :id)
    assert_equal 1, Transfer.where(external_id: "#{@family.id}:#{external_id}").count
  end

  test "requires write access to both transfer accounts" do
    function = Assistant::Function::CreateTransfer.new(users(:family_member))

    result = function.call(
      "from_account_id" => accounts(:depository).id,
      "to_account_id" => accounts(:credit_card).id,
      "amount" => 10,
      "date" => Date.current.iso8601,
      "external_id" => "transfer-auth-#{SecureRandom.uuid}"
    )

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end
end
