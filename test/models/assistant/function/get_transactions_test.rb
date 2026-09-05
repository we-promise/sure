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

  test "reports kind and entry id on every row" do
    result = @function.call("search" => @transaction.entry.name)

    row = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_equal @transaction.kind, row[:kind]
    assert_equal @transaction.entry.id, row[:entry_id]
  end

  test "flags a pending transaction and stays silent on a settled one" do
    @transaction.update!(extra: { "simplefin" => { "pending" => true } })

    result = @function.call("search" => @transaction.entry.name)
    row = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_equal true, row[:pending]

    @transaction.update!(extra: {})
    settled = @function.call("search" => @transaction.entry.name)
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_not settled.key?(:pending), "an absent key must mean not pending"
  end

  test "names the account on the other side of a transfer" do
    outflow_entry = Entry.create!(
      account: accounts(:depository),
      name: "Transfer out",
      date: Date.current,
      amount: 250,
      currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    inflow_entry = Entry.create!(
      account: accounts(:credit_card),
      name: "Transfer in",
      date: Date.current,
      amount: -250,
      currency: "USD",
      entryable: Transaction.new(kind: "cc_payment")
    )
    Transfer.create!(
      inflow_transaction: inflow_entry.entryable,
      outflow_transaction: outflow_entry.entryable
    )

    result = @function.call("search" => "Transfer out")
    row = result[:transactions].find { |item| item[:id] == outflow_entry.entryable.id }

    assert_equal true, row[:is_transfer]
    assert_equal "funds_movement", row[:kind]
    assert_equal accounts(:credit_card).name, row[:transfer_account]
  end

  # The visible leg belongs in the result; the account on the far end does not
  # belong to this user and naming it would disclose it.
  test "hides the counterparty account when the far leg is inaccessible" do
    outflow_entry = Entry.create!(
      account: accounts(:depository),
      name: "Transfer to private account",
      date: Date.current,
      amount: 250,
      currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    inflow_entry = Entry.create!(
      account: accounts(:investment),
      name: "Transfer in",
      date: Date.current,
      amount: -250,
      currency: "USD",
      entryable: Transaction.new(kind: "funds_movement")
    )
    Transfer.create!(
      inflow_transaction: inflow_entry.entryable,
      outflow_transaction: outflow_entry.entryable
    )

    result = Assistant::Function::GetTransactions.new(users(:family_member)).call("search" => "Transfer to private account")
    row = result[:transactions].find { |item| item[:id] == outflow_entry.entryable.id }

    assert_not_nil row, "the leg on the shared account is still visible"
    assert_equal true, row[:is_transfer]
    assert_not row.key?(:transfer_account), "an inaccessible counterparty must not be named"
  end

  test "omits transfer_account on a plain transaction" do
    result = @function.call("search" => @transaction.entry.name)
    row = result[:transactions].find { |item| item[:id] == @transaction.id }

    assert_not row.key?(:transfer_account)
  end

  test "cleans a raw bank label and surfaces the rail and operation date" do
    @transaction.entry.update!(name: "CB 02/09 CARREFOUR MARKET", date: Date.new(2026, 9, 5))

    row = @function.call("search" => "CARREFOUR")
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_equal "CB 02/09 CARREFOUR MARKET", row[:name]
    assert_equal "CARREFOUR MARKET", row[:clean_name]
    assert_equal "card", row[:rail]
    assert_equal Date.new(2026, 9, 2), row[:operation_date]
  end

  test "omits clean_name, rail and operation_date on a user-written name" do
    @transaction.entry.update!(name: "Groceries")

    row = @function.call("search" => "Groceries")
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_not row.key?(:clean_name)
    assert_not row.key?(:rail)
    assert_not row.key?(:operation_date)
  end

  test "omits operation_date when it matches the stored date" do
    @transaction.entry.update!(name: "CB 05/09 FNAC", date: Date.new(2026, 9, 5))

    row = @function.call("search" => "FNAC")
      .fetch(:transactions).find { |item| item[:id] == @transaction.id }

    assert_equal "FNAC", row[:clean_name]
    assert_not row.key?(:operation_date), "no point repeating the date the row already carries"
  end
end
