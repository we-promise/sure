require "test_helper"

class Assistant::Function::GetTransactionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @transaction = transactions(:one)
    @function = Assistant::Function::GetTransactions.new(@user)
  end

  test "returns transaction ids and notes" do
    @transaction.entry.update!(notes: "Visible note")

    result = @function.call(
      "page" => 1,
      "order" => "asc",
      "search" => @transaction.entry.name
    )

    transaction = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_not_nil transaction
    assert_equal @transaction.entry.notes, transaction[:notes]
  end

  test "excludes transactions from inaccessible accounts" do
    hidden_entry = Entry.create!(
      account: accounts(:investment),
      name: "Private investment transaction",
      date: Date.current,
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )
    hidden_entry.update!(notes: "Private note")

    result = Assistant::Function::GetTransactions.new(users(:family_member)).call(
      "page" => 1,
      "order" => "asc",
      "search" => hidden_entry.name
    )

    assert_empty result[:transactions]
  end
end
