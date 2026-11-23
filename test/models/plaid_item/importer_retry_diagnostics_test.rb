require "test_helper"
require "ostruct"

class PlaidItem::ImporterRetryDiagnosticsTest < ActiveSupport::TestCase
  # These assertions must observe a real import rollback, not a transaction
  # joined to the fixture transaction that rolls back only after the test.
  self.use_transactional_tests = false

  setup do
    @existing_log_ids = retry_logs.pluck(:id)
    @item = PlaidItem.create!(
      family: families(:dylan_family), name: "Retry diagnostics bank", plaid_id: "retry-item",
      access_token: "synthetic-token", next_cursor: "saved-cursor",
      billed_products: [ "transactions" ], available_products: []
    )
    @account = @item.plaid_accounts.create!(
      plaid_id: "retry-account", name: "Retry account", plaid_type: "depository",
      currency: "USD", current_balance: 1000
    )
    @provider = Provider::Plaid.new(Plaid::Configuration.new)
    @importer = PlaidItem::Importer.new(@item, plaid_provider: @provider)
    @importer.stubs(:fetch_and_import_item_data)

    raw_account = Plaid::AccountBase.new(
      account_id: @account.plaid_id, name: "Retry account", type: "depository",
      subtype: "checking", balances: Plaid::AccountBalance.new(current: 1234, iso_currency_code: "USD")
    )
    @provider.client.expects(:accounts_get).returns(OpenStruct.new(accounts: [ raw_account ]))
  end

  teardown do
    retry_logs.where.not(id: @existing_log_ids).delete_all
    if @item
      PlaidAccount.where(plaid_item_id: @item.id).delete_all
      PlaidItem.where(id: @item.id).delete_all
    end
  end

  test "retry diagnostics persist when transaction pagination exhausts its retries" do
    pages = sequence("transaction pages")
    error = mutation_error
    4.times do
      expect_page("saved-cursor", pages).returns(transaction_page("page-2", has_more: true))
      expect_page("page-2", pages).raises(error)
    end
    PlaidAccount::Importer.any_instance.expects(:import).never

    assert_difference -> { retry_logs.count }, 3 do
      assert_same error, assert_raises(Plaid::ApiError) { @importer.import }
    end

    assert_equal [ 1, 2, 3 ], retry_logs.order(:created_at).where.not(id: @existing_log_ids).map { |log| log.metadata.fetch("retry_count") }
    assert_equal "saved-cursor", @item.reload.next_cursor
    assert_equal 1000, @account.reload.current_balance
  end

  test "retry diagnostics survive a later import rollback without advancing the cursor" do
    pages = sequence("transaction pages")
    expect_page("saved-cursor", pages).raises(mutation_error)
    expect_page("saved-cursor", pages).returns(transaction_page("complete"))
    error = StandardError.new("Synthetic cursor persistence failure")
    @item.expects(:update!).with(next_cursor: "complete").raises(error)

    assert_difference -> { retry_logs.count }, 1 do
      assert_same error, assert_raises(StandardError) { @importer.import }
    end

    assert_equal "saved-cursor", @item.reload.next_cursor
    assert_equal 1000, @account.reload.current_balance
    log = retry_logs.where.not(id: @existing_log_ids).sole
    assert_equal({ "error_code" => "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", "retry_count" => 1 }, log.metadata)
  end

  private
    def retry_logs
      DebugLogEntry.where(source: "Provider::Plaid", message: "Restarting Plaid transaction pagination after data changed")
    end

    def expect_page(cursor, pages)
      @provider.client.expects(:transactions_sync).with { |request| request.cursor == cursor }.in_sequence(pages)
    end

    def transaction_page(cursor, has_more: false)
      OpenStruct.new(added: [], modified: [], removed: [], next_cursor: cursor, has_more: has_more)
    end

    def mutation_error
      Plaid::ApiError.new(code: 400, response_body: { error_code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" }.to_json)
    end
end
