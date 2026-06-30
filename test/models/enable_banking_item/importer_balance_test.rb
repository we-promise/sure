require "test_helper"
require "ostruct"

class EnableBankingItem::ImporterBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "CGD PT",
      country_code: "PT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @enable_banking_account = @enable_banking_item.enable_banking_accounts.create!(
      name: "CGD Current",
      uid: "identification_hash_1",
      account_id: "11111111-1111-1111-1111-111111111111",
      currency: "EUR",
      current_balance: 123.45,
      account_status: "active",
      provider: "enable_banking"
    )

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  test "fetch_and_update_balance prefers booked balance before available balance" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "ITAV",
          balance_amount: { amount: "1250.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "ITBD",
          balance_amount: { amount: "50.00", currency: "EUR" },
          credit_debit_indicator: "DBIT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("-50.00"), @enable_banking_account.reload.current_balance
  end

  test "fetch_and_update_balance handles descriptive booked balance types" do
    @mock_provider.stubs(:get_account_balances).returns(
      balances: [
        {
          balance_type: "interimAvailable",
          balance_amount: { amount: "2000.00", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        },
        {
          balance_type: "closingBooked",
          balance_amount: { amount: "321.09", currency: "EUR" },
          credit_debit_indicator: "CRDT"
        }
      ]
    )

    assert @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_equal BigDecimal("321.09"), @enable_banking_account.reload.current_balance
  end

  test "balance endpoint failure keeps previous balance and creates debug log" do
    error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API: {\"error\":\"BALANCES_UNAVAILABLE\"}",
      :bad_request,
      response_data: { error: "BALANCES_UNAVAILABLE", detail: { account_id: "redacted" } }
    )
    @mock_provider.stubs(:get_account_balances).raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    assert_equal BigDecimal("123.45"), @enable_banking_account.reload.current_balance

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_error", entry.category
    assert_equal "warn", entry.level
    assert_equal "enable_banking", entry.provider_key
    assert_equal "bad_request", entry.metadata["error_type"]
    assert_equal "BALANCES_UNAVAILABLE", entry.metadata.dig("response_data", "error")
  end

  test "import continues transaction sync when balance refresh fails" do
    depository = Depository.create!
    linked_account = Account.create!(
      family: @family,
      name: "CGD linked",
      balance: 123.45,
      cash_balance: 123.45,
      currency: "EUR",
      accountable: depository
    )
    AccountProvider.create!(account: linked_account, provider: @enable_banking_account)

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.expects(:fetch_and_update_balance).with(@enable_banking_account).returns(false)
    @importer.expects(:fetch_and_store_transactions).with(@enable_banking_account).returns(
      success: true,
      transactions_count: 2
    )

    result = @importer.import

    assert result[:success]
    assert_equal 2, result[:transactions_imported]
    assert_equal 0, result[:transactions_failed]
    assert_equal 1, result[:balances_failed]
  end
end
