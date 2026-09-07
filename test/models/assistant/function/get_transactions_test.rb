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

  test "schema no longer inlines user data enums" do
    schema = @function.params_schema

    %i[accounts categories merchants tags].each do |key|
      items = schema[:properties][key][:items]

      assert_equal({ type: "string" }, items, "#{key} should be a plain string array")
    end
  end

  test "honors page_size" do
    result = @function.call("page_size" => 1)

    assert_equal 1, result[:page_size]
    assert_equal 1, result[:transactions].size
    assert result[:total_pages] > 1
  end

  test "sorts by absolute amount" do
    result = @function.call("sort_by" => "amount", "order" => "desc")

    amounts = result[:transactions].map { |t| t[:amount].abs }

    assert_equal amounts.sort.reverse, amounts
  end

  test "filters by type" do
    result = @function.call("types" => [ "income" ])

    assert result[:transactions].any?
    assert result[:transactions].all? { |t| t[:classification] == "income" }
  end

  test "filters by account_ids and ignores inaccessible ids" do
    accessible_account = @transaction.entry.account

    result = @function.call("account_ids" => [ accessible_account.id ])

    assert result[:transactions].any?
    assert result[:transactions].all? { |t| t[:account] == accessible_account.name }

    member_result = Assistant::Function::GetTransactions.new(users(:family_member)).call(
      "account_ids" => [ accounts(:investment).id ]
    )

    assert_empty member_result[:transactions]
  end
end
