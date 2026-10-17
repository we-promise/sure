require "test_helper"

class PlaidAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
  end

  test "processes added and modified plaid transactions" do
    added_transactions = [ { "transaction_id" => "123" } ]
    modified_transactions = [ { "transaction_id" => "456" } ]

    @plaid_account.update!(raw_transactions_payload: {
      added: added_transactions,
      modified: modified_transactions,
      removed: []
    })

    mock_processor = mock("PlaidEntry::Processor")
    category_matcher_mock = mock("PlaidAccount::Transactions::CategoryMatcher")

    PlaidAccount::Transactions::CategoryMatcher.stubs(:new).returns(category_matcher_mock)
    PlaidEntry::Processor.expects(:new)
                         .with(added_transactions.first, plaid_account: @plaid_account, category_matcher: category_matcher_mock)
                         .returns(mock_processor)
                         .once

    PlaidEntry::Processor.expects(:new)
                         .with(modified_transactions.first, plaid_account: @plaid_account, category_matcher: category_matcher_mock)
                         .returns(mock_processor)
                         .once

    mock_processor.expects(:process).twice

    processor = PlaidAccount::Transactions::Processor.new(@plaid_account)
    processor.process
  end

  test "removes imported transactions that plaid retracts" do
    account = @plaid_account.current_account
    retracted_id = "retracted_by_plaid"

    Account::ProviderImportAdapter.new(account).import_transaction(
      external_id: retracted_id,
      amount: 100,
      currency: "USD",
      date: Date.current,
      name: "Retracted",
      source: PlaidEntry::Processor::SOURCE
    )

    # The import path does not set plaid_id, so a lookup on it alone finds nothing.
    assert_nil account.entries.find_by(external_id: retracted_id).plaid_id

    @plaid_account.update!(raw_transactions_payload: {
      added: [],
      modified: [],
      removed: [ { "transaction_id" => retracted_id } ]
    })

    assert_difference [ "Entry.count", "Transaction.count" ], -1 do
      PlaidAccount::Transactions::Processor.new(@plaid_account).process
    end

    assert_nil account.entries.find_by(external_id: retracted_id)
  end

  test "leaves another provider's entry with the same external id alone" do
    account = @plaid_account.current_account
    shared_id = "shared_external_id"

    Account::ProviderImportAdapter.new(account).import_transaction(
      external_id: shared_id,
      amount: 100,
      currency: "USD",
      date: Date.current,
      name: "Not from Plaid",
      source: "simplefin"
    )

    @plaid_account.update!(raw_transactions_payload: {
      added: [],
      modified: [],
      removed: [ { "transaction_id" => shared_id } ]
    })

    assert_no_difference "Entry.count" do
      PlaidAccount::Transactions::Processor.new(@plaid_account).process
    end
  end

  test "removes transactions no longer in plaid" do
    destroyable_transaction_id = "destroy_me"
    @plaid_account.current_account.entries.create!(
      plaid_id: destroyable_transaction_id,
      date: Date.current,
      amount: 100,
      name: "Destroy me",
      currency: "USD",
      entryable: Transaction.new
    )

    @plaid_account.update!(raw_transactions_payload: {
      added: [],
      modified: [],
      removed: [ { "transaction_id" => destroyable_transaction_id } ]
    })

    processor = PlaidAccount::Transactions::Processor.new(@plaid_account)

    assert_difference [ "Entry.count", "Transaction.count" ], -1 do
      processor.process
    end

    assert_nil Entry.find_by(plaid_id: destroyable_transaction_id)
  end
end
