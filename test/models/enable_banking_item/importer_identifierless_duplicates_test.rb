require "test_helper"

class EnableBankingItem::ImporterIdentifierlessDuplicatesTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @account.update!(currency: "EUR")
    @item = EnableBankingItem.create!(
      family: @account.family,
      name: "Test bank",
      country_code: "FR",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @provider_account = EnableBankingAccount.create!(
      enable_banking_item: @item,
      name: "Current account",
      uid: "test-identifierless-duplicates",
      account_id: "a3e2f9d1-1c4b-4a6e-9f2b-0d5c8e7a6b43",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @provider_account)

    @provider = mock()
    @provider.stubs(:get_session).returns(accounts: [ @provider_account.uid ])
    @provider.stubs(:get_account_balances).returns(
      balances: [ { balance_type: "CLBD", balance_amount: { amount: "100.00", currency: "EUR" } } ]
    )
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "PDNG")).returns(transactions: [])
    @importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: @provider)
  end

  test "imports two identical identifierless top-ups from one response as two entries" do
    # Revolut via Enable Banking omits both identifiers and can return two real
    # same-day top-ups of the same amount from the same counterparty.
    rows = [ identifierless_top_up, identifierless_top_up ]
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "BOOK")).returns(transactions: rows)

    import_and_process

    entries = imported_entries.order(:external_id)
    assert_equal 2, entries.count
    assert_equal [ BigDecimal("-400.00") ], [ entries.sum(:amount) ]
    assert_equal 2, entries.pluck(:external_id).uniq.count
    assert_equal [ 0, 1 ], @provider_account.reload.raw_transactions_payload.map { |tx| tx["_content_occurrence"] }

    # A later sync of the same response is idempotent.
    assert_no_difference -> { imported_entries.count } do
      import_and_process
    end
  end

  private
    def identifierless_top_up
      {
        booking_date: Date.current.to_s,
        value_date: Date.current.to_s,
        transaction_amount: { amount: "200.00", currency: "EUR" },
        credit_debit_indicator: "CRDT",
        debtor: { name: "Own account" },
        remittance_information: [ "Apple Pay top-up" ],
        status: "BOOK"
      }
    end

    def import_and_process
      result = @importer.import
      assert result[:success], result.inspect
      processing = EnableBankingAccount::Transactions::Processor.new(@provider_account.reload).process
      assert processing[:success], processing.inspect
    end

    def imported_entries
      @account.entries.where(source: "enable_banking", entryable_type: "Transaction")
    end
end
