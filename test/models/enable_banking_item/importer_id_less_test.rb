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

  # An ASPSP that sends only date, amount, currency and direction: two
  # same-day transfers of the same amount are, as far as the response can say,
  # two identical rows. Both must reach the payload and the ledger.
  def bare_tx(amount: "100.00", date: Date.current.to_s)
    {
      booking_date: date,
      transaction_amount: { amount: amount, currency: "RON" },
      credit_debit_indicator: "CRDT",
      status: "BOOK"
    }
  end

  def stub_fetch(booked)
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns(booked)
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)
  end

  test "keeps two identical bare rows from one response, end to end" do
    stub_fetch([ bare_tx, bare_tx ])

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
    assert_equal 2, @enable_banking_account.raw_transactions_payload.count, "the in-response dedup must not collapse them"

    assert_difference "@account.entries.where(source: \"enable_banking\").count", 2 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "stores the second of two identical bare rows when it arrives on a later sync" do
    stub_fetch([ bare_tx ])
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count

    # The day's second transfer shows up next time, beside the first.
    stub_fetch([ bare_tx, bare_tx ])
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
    assert_equal 2, @enable_banking_account.raw_transactions_payload.count

    # And a third sync of the same response adds nothing.
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
    assert_equal 2, @enable_banking_account.raw_transactions_payload.count
  end

  test "does not store an id-less row again when only a field the hash does not read has changed" do
    stub_fetch([ bare_tx.merge(value_date: Date.current.to_s) ])
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    stub_fetch([ bare_tx.merge(value_date: 1.day.ago.to_date.to_s) ])
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
  end

  # A truncated response may leave a stored row out. If it carries a new row
  # with the same content hash in its place, the group has not grown, and
  # counting alone would skip the new row for good.
  test "stores a new row from a truncated response even when the group did not grow" do
    stored = bare_tx.merge(note: "first transfer")
    @enable_banking_account.update!(raw_transactions_payload: [ stored ])

    page1 = { transactions: [ bare_tx.merge(note: "second transfer") ], continuation_key: "next" }
    truncation = Provider::EnableBanking::EnableBankingError.new("transactionStatus in request is not the same as in continuationKey", :validation_error)
    @mock_provider.stubs(:get_account_transactions).returns(page1).then.raises(truncation)
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)
    @enable_banking_item.stubs(:build_psu_headers).returns({})

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    notes = @enable_banking_account.raw_transactions_payload.map { |tx| tx["note"] }
    assert_equal [ "first transfer", "second transfer" ], notes.sort
  end

  # Booked and pending rows come from separate fetches. A pending fetch cut
  # short must not loosen the rule for booked rows from a complete fetch.
  test "a truncated pending fetch does not let an edited booked row be stored twice" do
    @enable_banking_account.update!(raw_transactions_payload: [ bare_tx.merge(note: "first transfer") ])

    edited = { transactions: [ bare_tx.merge(note: "first transfer, edited") ], continuation_key: nil }
    pending_page = { transactions: [ bare_tx(amount: "7.00") ], continuation_key: "next" }
    truncation = Provider::EnableBanking::EnableBankingError.new("transactionStatus in request is not the same as in continuationKey", :validation_error)
    @mock_provider.stubs(:get_account_transactions).with(has_entry(transaction_status: "BOOK")).returns(edited)
    @mock_provider.stubs(:get_account_transactions).with(has_entry(transaction_status: "PDNG")).returns(pending_page).then.raises(truncation)
    @importer.stubs(:include_pending?).returns(true)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)
    @enable_banking_item.stubs(:build_psu_headers).returns({})

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    booked = @enable_banking_account.raw_transactions_payload.reject { |tx| tx["_pending"] }
    assert_equal 1, booked.count, "the edited booked row is the stored one, not a second transaction"
  end

  test "a complete response still does not store an edited row twice" do
    stored = bare_tx.merge(note: "first transfer")
    @enable_banking_account.update!(raw_transactions_payload: [ stored ])

    stub_fetch([ bare_tx.merge(note: "first transfer, edited") ])
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
  end

  test "still collapses rows that differ only in entry_reference (issue #954)" do
    stub_fetch([ bare_tx.merge(entry_reference: "ref_a"), bare_tx.merge(entry_reference: "ref_b") ])
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
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
