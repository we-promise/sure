require "test_helper"

class OpenBankingIoItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://staging.open-banking.io",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
    @provider_account = OpenBankingIoAccount.create!(
      open_banking_io_item: @item,
      name: "Everyday",
      account_id: "acc_1",
      currency: "EUR"
    )
    @importer = OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: nil)
  end

  def store(txns)
    @importer.send(:store_transactions, @provider_account, transactions: txns)
    @provider_account.reload.raw_transactions_payload.to_a
  end

  # Fix 1: storage must update in place so a pending row that settles to booked
  # under the SAME id replaces the stored pending row instead of being dropped
  # as a duplicate (which would leave the entry stuck pending forever).
  test "a booked transaction reusing a pending transaction id replaces the stored pending row in place" do
    store([ { "id" => "P", "status" => "PDNG", "credit_debit_indicator" => "DBIT", "amount" => "10.00", "booking_date" => "2026-01-10" } ])

    stored = store([ { "id" => "P", "status" => "BOOK", "credit_debit_indicator" => "DBIT", "amount" => "12.00", "booking_date" => "2026-01-11" } ])

    assert_equal 1, stored.size
    row = stored.first.with_indifferent_access
    assert_equal "BOOK", row[:status]
    assert_equal "12.00", row[:amount]
    assert_equal "2026-01-11", row[:booking_date]
  end

  # Fix 2: an ISO-20022 transaction that arrives with no `id` must still be stored
  # under a stable content-hash key rather than being silently dropped.
  test "an id-less transaction is stored under a stable content-hash key rather than dropped" do
    txn = { "status" => "PDNG", "credit_debit_indicator" => "DBIT", "amount" => "9.99", "booking_date" => "2026-02-01", "creditor_name" => "Spotify", "remittance_information" => "Subscription" }

    stored = store([ txn ])
    assert_equal 1, stored.size

    # Re-storing identical id-less content must not create a duplicate row.
    stored_again = store([ txn.dup ])
    assert_equal 1, stored_again.size
  end
end
