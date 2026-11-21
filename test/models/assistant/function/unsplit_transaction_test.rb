require "test_helper"

class Assistant::Function::UnsplitTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @entry = create_transaction(account: accounts(:depository), amount: 590, name: "Rent")
    @children = @entry.split!([ { name: "A", amount: 295 }, { name: "B", amount: 295 } ])
    @function = Assistant::Function::UnsplitTransaction.new(@user)
  end

  test "removes the parts and restores the original" do
    child_ids = @children.map(&:id)
    child_transaction_ids = @children.map(&:entryable_id)

    result = @function.call("id" => @entry.entryable_id)

    assert_equal true, result[:success], result[:message]
    @entry.reload
    assert_not @entry.split_parent?
    assert_not @entry.excluded?
    assert_empty result[:transaction][:children]
    assert_empty Entry.where(id: child_ids)
    assert_empty Transaction.where(id: child_transaction_ids)
  end

  test "accepts the id of a part" do
    result = @function.call("id" => @children.first.entryable_id)

    assert_equal true, result[:success], result[:message]
    assert_not @entry.reload.split_parent?
  end

  test "reports transactions that are not split" do
    entry = create_transaction(account: accounts(:depository), amount: 10)

    result = @function.call("id" => entry.entryable_id)

    assert_equal "not_split", result[:error]
  end

  test "does not let read-only collaborators unsplit" do
    entry = create_transaction(account: accounts(:credit_card), amount: 100)
    entry.split!([ { name: "A", amount: 50 }, { name: "B", amount: 50 } ])

    result = Assistant::Function::UnsplitTransaction.new(users(:family_member)).call("id" => entry.entryable_id)

    assert_equal "not_authorized", result[:error]
    assert entry.reload.split_parent?
  end
end
