require "test_helper"

# Some ASPSPs re-issue transaction_id and entry_reference on every response, so
# two fetches describe the same movement under different identifiers. The
# snapshot must be replaced for the window fetched rather than appended to, and
# the entries carried over to the new identifiers.
class EnableBankingItem::ImporterRotatingIdsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "NO",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Current Account",
      uid: "hash_rotating_ids_test",
      account_id: "uuid-rotating-1234",
      currency: "NOK"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @provider)
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(1.month.ago.to_date)
  end

  # Same movement, a fresh identifier on each call.
  def rotating_tx(nonce, amount: "100.00", date: Date.current.to_s, counterparty: "Acme")
    {
      transaction_id: "txn_#{nonce}",
      entry_reference: "ref_#{nonce}",
      booking_date: date,
      transaction_amount: { amount: amount, currency: "NOK" },
      credit_debit_indicator: "DBIT",
      creditor: { name: counterparty },
      status: "BOOK"
    }
  end

  def stub_fetch(booked, pending: [], pending_raises: nil)
    @importer.stubs(:fetch_paginated_transactions)
             .with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns(booked)
    if pending_raises
      @importer.stubs(:fetch_paginated_transactions)
               .with(@enable_banking_account, has_entry(transaction_status: "PDNG")).raises(pending_raises)
    else
      @importer.stubs(:fetch_paginated_transactions)
               .with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns(pending)
    end
  end

  def sync(booked, **opts)
    stub_fetch(booked, **opts)
    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    @enable_banking_account.reload
  end

  def sync_and_process(booked, **opts)
    sync(booked, **opts)
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
  end

  def snapshot_count = @enable_banking_account.reload.raw_transactions_payload.count
  def entry_count = Entry.where(account_id: @account.id, source: "enable_banking").count

  test "entries are carried over when the ASPSP rotates identifiers" do
    sync_and_process([ rotating_tx("aaa") ])
    assert_equal 1, entry_count

    sync_and_process([ rotating_tx("bbb") ])
    assert_equal 1, entry_count, "a rotated identifier must not insert a second entry"
    assert_equal 1, snapshot_count

    sync_and_process([ rotating_tx("ccc") ])
    assert_equal 1, entry_count
  end

  test "a re-keyed entry keeps the annotations made on it" do
    sync_and_process([ rotating_tx("aaa") ])
    entry = Entry.find_by(account_id: @account.id, source: "enable_banking")
    category = @family.categories.create!(name: "Groceries #{SecureRandom.hex(4)}")
    entry.entryable.update!(category: category)
    entry.update!(notes: "keep me")

    sync_and_process([ rotating_tx("bbb") ])

    entry.reload
    assert_equal category.id, entry.entryable.category_id
    assert_equal "keep me", entry.notes
  end

  test "genuinely repeated movements keep their multiplicity" do
    three = %w[t1 t2 t3].map { |n| rotating_tx(n, amount: "10.00", counterparty: "Repeat") }
    sync_and_process(three)
    assert_equal 3, snapshot_count
    assert_equal 3, entry_count

    sync_and_process(%w[t4 t5 t6].map { |n| rotating_tx(n, amount: "10.00", counterparty: "Repeat") })
    assert_equal 3, snapshot_count, "must not collapse distinct same-day movements (see #2720)"
    assert_equal 3, entry_count
  end

  test "retains stored rows that predate the fetched window" do
    old_row = rotating_tx("old", date: 6.months.ago.to_date.to_s, amount: "999.00")
    @enable_banking_account.upsert_enable_banking_transactions_snapshot!([ old_row ])

    sync([ rotating_tx("new") ])

    stored = @enable_banking_account.raw_transactions_payload.map(&:with_indifferent_access)
    assert_equal 2, stored.count
    assert stored.any? { |t| t[:transaction_amount][:amount].to_s == "999.00" }
  end

  test "an empty response does not wipe the stored window" do
    sync([ rotating_tx("aaa") ])
    assert_equal 1, snapshot_count

    sync([])
    assert_equal 1, snapshot_count, "a transient empty fetch must not erase history"
  end

  test "an unsupported PDNG fetch still reconciles the complete booked window" do
    @importer.stubs(:include_pending?).returns(true)
    sync_and_process([ rotating_tx("aaa") ], pending: [])
    assert_equal 1, snapshot_count
    assert_equal 1, entry_count

    # The BOOK request succeeded in full; only PDNG was refused. Declaring the
    # whole fetch incomplete would leave the booked rotation unreconciled.
    unsupported = Provider::EnableBanking::EnableBankingError.new("PDNG unsupported", :validation_error)
    sync_and_process([ rotating_tx("bbb") ], pending_raises: unsupported)

    stored = @enable_banking_account.raw_transactions_payload.map(&:with_indifferent_access)
    assert_equal 1, stored.count, "the complete booked window must still be replaced"
    assert_equal "txn_bbb", stored.first[:transaction_id]
    assert_equal 1, entry_count, "a rotated identifier must not insert a second entry"
  end

  test "an unsupported PDNG fetch keeps stored pending rows" do
    @importer.stubs(:include_pending?).returns(true)
    pending_row = rotating_tx("pend", amount: "55.00", counterparty: "Pending Co").merge(_pending: true)
    @enable_banking_account.upsert_enable_banking_transactions_snapshot!([ pending_row ])

    unsupported = Provider::EnableBanking::EnableBankingError.new("PDNG unsupported", :validation_error)
    sync([ rotating_tx("bbb") ], pending_raises: unsupported)

    stored = @enable_banking_account.raw_transactions_payload.map(&:with_indifferent_access)
    assert stored.any? { |t| t[:transaction_id] == "txn_pend" },
      "PDNG was never fetched, so stored pending rows cannot be shown to be gone"
  end

  test "a truncated pagination run does not replace the window" do
    sync([ rotating_tx("aaa") ])
    assert_equal 1, snapshot_count

    # Real pagination this time: the ASPSP repeats its continuation_key, which
    # fetch_paginated_transactions tolerates by returning the pages it did get.
    @importer.unstub(:fetch_paginated_transactions)
    @provider.stubs(:get_account_transactions)
             .returns({ transactions: [ rotating_tx("bbb") ], continuation_key: "k1" })
             .then.returns({ transactions: [], continuation_key: "k1" })

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    stored = @enable_banking_account.reload.raw_transactions_payload.map(&:with_indifferent_access)
    assert_equal 2, stored.count, "a partial page set must not evict rows it never covered"
    assert stored.any? { |t| t[:transaction_id] == "txn_aaa" }, "the unfetched row must survive"
  end

  test "a reordered response does not move annotations between repeated movements" do
    a = rotating_tx("a", amount: "10.00", counterparty: "Repeat")
    b = rotating_tx("b", amount: "10.00", counterparty: "Repeat")
    sync_and_process([ a, b ])
    assert_equal 2, entry_count

    b_id = EnableBankingEntry::Processor.compute_external_id(b.with_indifferent_access)
    b_entry = Entry.find_by!(account_id: @account.id, source: "enable_banking", external_id: b_id)
    b_entry.update!(notes: "belongs to b")

    # b keeps its identifier, a rotates to c, and the order flips.
    c = rotating_tx("c", amount: "10.00", counterparty: "Repeat")
    sync_and_process([ b, c ])

    assert_equal 2, entry_count, "pairing must not orphan an entry and insert a replacement"
    assert_equal "belongs to b", Entry.find_by(account_id: @account.id, source: "enable_banking", external_id: b_id)&.notes,
      "an unchanged identifier must keep its own annotations"
  end

  test "a numeric timestamp is read as a timestamp, not as a four-digit year" do
    start_date = Date.new(2026, 9, 12)
    # 1791072000 is 2026-10-04, well inside the window. Read as digits it is also
    # a parseable date in the year 1791, so a plain Date.parse discards a recent
    # transaction outright. Other epochs raise instead and are kept regardless of
    # their age; both readings are wrong, and neither matches in_fetched_window?.
    in_window = { transaction_id: "epoch_in", booking_date: 1791072000 }
    out_of_window = { transaction_id: "epoch_out", booking_date: Date.new(2026, 1, 5).to_time.to_i }

    kept = @importer.send(:filter_transactions_by_date, [ in_window, out_of_window ], start_date)

    assert_equal [ "epoch_in" ], kept.map { |tx| tx[:transaction_id] }
  end

  test "a failed snapshot write rolls back the re-keyed identifiers" do
    sync_and_process([ rotating_tx("aaa") ])
    entry = Entry.find_by!(account_id: @account.id, source: "enable_banking")
    old_external_id = entry.external_id

    @enable_banking_account.stubs(:upsert_enable_banking_transactions_snapshot!).raises(ActiveRecord::StatementInvalid, "boom")
    sync([ rotating_tx("bbb") ])

    assert_equal old_external_id, entry.reload.external_id,
      "re-keying must not outlive the snapshot write it was paired with"
  end

  test "rows dated with a unix timestamp are matched to the window" do
    epoch_row = rotating_tx("epoch").merge(booking_date: Time.current.to_i)
    @enable_banking_account.upsert_enable_banking_transactions_snapshot!([ epoch_row ])

    sync([ rotating_tx("fresh") ])

    assert_equal 1, snapshot_count,
      "a timestamp-dated row inside the window must be superseded, not duplicated"
  end
end
