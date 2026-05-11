require "test_helper"

class EnableBankingItem::ImporterIdLessTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "RO",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Current Account",
      uid: "hash_idless_test",
      account_id: "uuid-idless-1234-abcd",
      currency: "RON"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @mock_provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  def id_less_tx(amount: "50.00", creditor: "Kaufland", date: Date.current.to_s)
    {
      booking_date: date,
      transaction_amount: { amount: amount, currency: "RON" },
      credit_debit_indicator: "DBIT",
      creditor: { name: creditor }
    }
  end

  test "stores id-less transactions in raw_transactions_payload on first sync" do
    tx = id_less_tx

    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns([ tx ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
  end

  test "does not re-store id-less transaction on second sync" do
    tx = id_less_tx

    # First sync
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns([ tx ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count

    # Second sync with the same transaction
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
  end

  test "stores multiple distinct id-less transactions separately" do
    tx1 = id_less_tx(amount: "50.00", creditor: "Kaufland")
    tx2 = id_less_tx(amount: "12.50", creditor: "Starbucks")

    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns([ tx1, tx2 ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 2, @enable_banking_account.raw_transactions_payload.count
  end

  test "removes stored id-less pending entry when its booked counterpart arrives" do
    tx = id_less_tx(amount: "30.00", creditor: "Netflix")
    pending_tx = tx.merge(_pending: true)

    @enable_banking_account.update!(raw_transactions_payload: [ pending_tx ])

    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns([ tx ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([])
    @importer.stubs(:include_pending?).returns(true)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    stored = @enable_banking_account.raw_transactions_payload
    assert_equal 1, stored.count
    assert_nil stored.first["_pending"]
  end

  # Regression: pending row has entry_reference only; booked counterpart gains
  # transaction_id on settlement. Fingerprints diverge but entry_reference is
  # stable — the pending entry must still be removed from stored payload.
  test "removes stored pending entry when settled book row gains a transaction_id" do
    entry_ref = "REF-SETTLE-123"

    pending_tx = {
      "entry_reference" => entry_ref,
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "15.00", "currency" => "RON" },
      "credit_debit_indicator" => "DBIT",
      "creditor" => { "name" => "Bolt" },
      "_pending" => true
    }

    booked_tx = {
      transaction_id: "TXN-NEW-456",
      entry_reference: entry_ref,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "15.00", currency: "RON" },
      credit_debit_indicator: "DBIT",
      creditor: { name: "Bolt" }
    }

    @enable_banking_account.update!(raw_transactions_payload: [ pending_tx ])

    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns([ booked_tx ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([])
    @importer.stubs(:include_pending?).returns(true)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    stored = @enable_banking_account.raw_transactions_payload
    assert_equal 1, stored.count, "Stale pending entry should have been removed"
    assert_nil stored.first["_pending"], "Remaining entry should be the booked row"
  end
end
