require "test_helper"

class Assistant::Function::FinancialUpdateLockingTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
  end

  test "locks account before changing its balance" do
    Account.any_instance.expects(:lock!).at_least_once

    result = Assistant::Function::UpdateAccount.new(@user).call(
      "id" => accounts(:depository).id,
      "balance" => 250
    )

    assert_equal true, result[:success]
  end

  test "locks transaction and entry before recomputing financial fields" do
    Transaction.any_instance.expects(:lock!).once
    Entry.any_instance.expects(:lock!).once

    result = Assistant::Function::UpdateTransaction.new(@user).call(
      "id" => transactions(:one).id,
      "amount" => 250
    )

    assert_equal true, result[:success]
  end

  test "locks entry and transaction before deleting" do
    Entry.any_instance.expects(:lock!).once
    Transaction.any_instance.expects(:lock!).once

    result = Assistant::Function::DeleteTransaction.new(@user).call("id" => transactions(:one).id)

    assert_equal true, result[:success]
  end

  test "locks transfer and both entries before recomputing its legs" do
    destination = @family.accounts.create!(
      owner: @user,
      name: "Locking destination",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )
    created = Assistant::Function::CreateTransfer.new(@user).call(
      "from_account_id" => accounts(:depository).id,
      "to_account_id" => destination.id,
      "amount" => 25,
      "date" => Date.current.iso8601,
      "external_id" => "locking-#{SecureRandom.uuid}"
    )
    Transfer.any_instance.expects(:lock!).once
    Entry.any_instance.expects(:lock!).twice

    result = Assistant::Function::UpdateTransfer.new(@user).call(
      "id" => created.dig(:transfer, :id),
      "amount" => 30
    )

    assert_equal true, result[:success]
  end
end
