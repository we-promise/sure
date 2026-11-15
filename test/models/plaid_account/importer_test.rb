require "test_helper"

class PlaidAccount::ImporterTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @mock_account_snapshot = mock
  end

  test "imports account data" do
    account_data = OpenStruct.new(
      account_id: "acc_1",
      name: "Test Account",
      mask: "1234",
    )

    transactions_data = OpenStruct.new(
      added: [],
      modified: [],
      removed: [],
    )

    investments_data = OpenStruct.new(
      holdings: [],
      transactions: [],
      securities: [],
    )

    liabilities_data = OpenStruct.new(
      credit: [],
      mortgage: [],
      student: [],
    )

    @mock_account_snapshot.expects(:account_data).returns(account_data).at_least_once
    @mock_account_snapshot.expects(:transactions_data).returns(transactions_data).at_least_once
    @mock_account_snapshot.expects(:investments_data).returns(investments_data).at_least_once
    @mock_account_snapshot.expects(:liabilities_data).returns(liabilities_data).at_least_once

    @plaid_account.expects(:upsert_plaid_snapshot!).with(account_data)
    @plaid_account.expects(:upsert_plaid_transactions_snapshot!).with(transactions_data)
    @plaid_account.expects(:upsert_plaid_holdings_snapshot!).with(investments_data)
    @plaid_account.expects(:upsert_plaid_liabilities_snapshot!).with(liabilities_data)

    PlaidAccount::Importer.new(@plaid_account, account_snapshot: @mock_account_snapshot).import
  end

  # A sync that fetched no liabilities would otherwise process the payload a
  # previous sync stored, and a variable loan would record that old rate as a
  # change dated to this sync.
  test "a sync without liabilities data clears the stored liabilities payload" do
    @plaid_account.update!(raw_liabilities_payload: { "mortgage" => { "interest_rate" => { "percentage" => 4.5 } } })
    snapshot = OpenStruct.new(account_data: nil, transactions_data: nil, investments_data: nil, liabilities_data: nil)
    @plaid_account.stubs(:upsert_plaid_snapshot!)

    PlaidAccount::Importer.new(@plaid_account, account_snapshot: snapshot).import

    assert_equal({}, @plaid_account.reload.raw_liabilities_payload)
  end

  test "a sync without liabilities data leaves an account that never had them unwritten" do
    @plaid_account.update_columns(raw_liabilities_payload: nil)
    snapshot = OpenStruct.new(account_data: nil, transactions_data: nil, investments_data: nil, liabilities_data: nil)
    @plaid_account.stubs(:upsert_plaid_snapshot!)
    @plaid_account.expects(:upsert_plaid_liabilities_snapshot!).never

    PlaidAccount::Importer.new(@plaid_account, account_snapshot: snapshot).import

    assert_nil @plaid_account.reload.raw_liabilities_payload
  end
end
