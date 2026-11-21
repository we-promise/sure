require "test_helper"

class Rule::ActionExecutor::SetTransactionNameFromAdditionalDetailTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @rule = rules(:one)
    @account = @family.accounts.create!(name: "Additional detail test", balance: 1000, currency: "USD", accountable: Depository.new)
    @executor = Rule::ActionExecutor::SetTransactionNameFromAdditionalDetail.new(@rule)
  end

  test "names a transaction from the detail field at any depth" do
    txn = transaction_with_extra("enable_banking" => { "counterparty_address" => "EXAMPLE MARKET 0042 TESTOWO" })

    @executor.execute(@account.transactions, value: "counterparty_address")

    assert_equal "EXAMPLE MARKET 0042 TESTOWO", txn.reload.entry.name
  end

  test "leaves transactions that lack the field unchanged" do
    untouched = create_transaction(account: @account, name: "No details").transaction
    other_field = transaction_with_extra("plaid" => { "memo" => "Coffee shop" })

    @executor.execute(@account.transactions, value: "counterparty_address")

    assert_equal "No details", untouched.reload.entry.name
    assert_equal "Original name", other_field.reload.entry.name
  end

  test "ignores a non-string value under the key" do
    txn = transaction_with_extra("enable_banking" => { "counterparty_address" => { "line" => "Example Market" } })

    @executor.execute(@account.transactions, value: "counterparty_address")

    assert_equal "Original name", txn.reload.entry.name
  end

  test "respects a locked name" do
    txn = transaction_with_extra("enable_banking" => { "counterparty_address" => "Example Market" })
    txn.entry.lock_attr!(:name)

    @executor.execute(@account.transactions, value: "counterparty_address")

    assert_equal "Original name", txn.reload.entry.name
  end

  test "overrides a locked name when ignore_attribute_locks is true" do
    txn = transaction_with_extra("enable_banking" => { "counterparty_address" => "Example Market" })
    txn.entry.lock_attr!(:name)

    @executor.execute(@account.transactions, value: "counterparty_address", ignore_attribute_locks: true)

    assert_equal "Example Market", txn.reload.entry.name
  end

  test "does nothing when the key is blank" do
    txn = transaction_with_extra("enable_banking" => { "counterparty_address" => "Example Market" })

    assert_equal 0, @executor.execute(@account.transactions, value: " ")

    assert_equal "Original name", txn.reload.entry.name
  end

  test "reports the copied field as its display value" do
    assert_equal "counterparty_address", @executor.value_display("counterparty_address")
    assert_nil @executor.value_display("")
  end

  test "prefers a key at the current level over a deeper one regardless of key order" do
    txn = transaction_with_extra(
      "a" => { "counterparty_address" => "deep" },
      "counterparty_address" => "shallow"
    )

    @executor.execute(@account.transactions, value: "counterparty_address")

    assert_equal "shallow", txn.reload.entry.name
  end

  test "does not reserve the name for rows it leaves alone" do
    assert_not @executor.reserves_claimed_attributes?
  end

  test "is a supported action type" do
    assert_includes Rule::Action::SUPPORTED_ACTION_TYPES, "set_transaction_name_from_additional_detail"

    action = Rule::Action.new(
      rule: @rule,
      action_type: "set_transaction_name_from_additional_detail",
      value: "counterparty_address"
    )
    assert action.valid?
  end

  private
    def transaction_with_extra(extra)
      txn = create_transaction(account: @account, name: "Original name").transaction
      txn.update!(extra: extra)
      txn
    end
end
