require "test_helper"

class Assistant::Function::UpdateTransferTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::UpdateTransfer.new(@user)
    @transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:investment), amount: 300)
    @transfer.outflow_transaction.update!(kind: "investment_contribution")
  end

  test "is registered for the assistant and MCP" do
    assert_includes Assistant.function_classes(@user), Assistant::Function::UpdateTransfer
  end

  test "turns an investment contribution into a plain transfer by either transaction" do
    result = @function.call("transaction_id" => @transfer.inflow_transaction.id, "investment_contribution" => false)

    assert result[:success]
    assert_equal false, result[:transfer][:investment_contribution]
    assert_equal "funds_movement", result[:transfer][:outflow][:kind]
    assert_equal "funds_movement", @transfer.outflow_transaction.reload.kind
    assert @transfer.outflow_transaction.locked?(:kind)
  end

  test "turns a plain transfer back into an investment contribution" do
    assert @transfer.reload.update_investment_contribution!(false)

    result = @function.call("transfer_id" => @transfer.id, "investment_contribution" => true)

    assert result[:success]
    assert_equal true, result[:transfer][:investment_contribution]
    assert_equal "investment_contribution", @transfer.outflow_transaction.reload.kind
  end

  test "dry run describes the change without making it" do
    result = @function.call("transfer_id" => @transfer.id, "investment_contribution" => false, "dry_run" => true)

    assert result[:success]
    assert result[:dry_run]
    assert_equal true, result[:transfer][:investment_contribution]
    assert_equal "investment_contribution", @transfer.outflow_transaction.reload.kind
  end

  test "refuses a transfer that cannot be an investment contribution" do
    payment = create_transfer(from_account: accounts(:depository), to_account: accounts(:credit_card), amount: 50)

    result = @function.call("transfer_id" => payment.id, "investment_contribution" => false)

    assert_not result[:success]
    assert_equal "not_switchable", result[:error]
  end

  test "requires write access to both accounts" do
    accounts(:investment).account_shares.create!(user: users(:family_member), permission: "read_only")

    result = Assistant::Function::UpdateTransfer.new(users(:family_member))
      .call("transfer_id" => @transfer.id, "investment_contribution" => false)

    assert_not result[:success]
    assert_equal "not_found", result[:error]
    assert_equal "investment_contribution", @transfer.outflow_transaction.reload.kind
  end

  test "reads a string false from a loose client as false" do
    result = @function.call("transfer_id" => @transfer.id, "investment_contribution" => "false")

    assert result[:success]
    assert_equal "funds_movement", @transfer.outflow_transaction.reload.kind
  end

  test "rejects a value that is not a boolean" do
    assert @transfer.reload.update_investment_contribution!(false)

    result = @function.call("transfer_id" => @transfer.id, "investment_contribution" => "no")

    assert_not result[:success]
    assert_equal "invalid_arguments", result[:error]
    assert_equal "funds_movement", @transfer.outflow_transaction.reload.kind
  end

  test "requires a change to make" do
    result = @function.call("transfer_id" => @transfer.id)

    assert_not result[:success]
    assert_equal "invalid_arguments", result[:error]
  end
end
