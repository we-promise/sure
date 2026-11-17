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

  def stub_fetch(booked, pending: [], pending_raises: nil, truncated: false, window_start: nil)
    @importer.stubs(:fetch_paginated_transactions)
             .with(@enable_banking_account, has_entry(transaction_status: "BOOK")).returns([ booked, truncated, window_start ])
    if pending_raises
      @importer.stubs(:fetch_paginated_transactions)
               .with(@enable_banking_account, has_entry(transaction_status: "PDNG")).raises(pending_raises)
    else
      @importer.stubs(:fetch_paginated_transactions)
               .with(@enable_banking_account, has_entry(transaction_status: "PDNG")).returns([ pending, false ])
    end
  end

  def sync(booked, account: @enable_banking_account, **opts)
    stub_fetch(booked, **opts)
    @importer.send(:fetch_and_store_transactions, account)
    @enable_banking_account.reload
  end

  def sync_and_process(booked, **opts)
    sync(booked, **opts)
    process
  end

  def process = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process

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
    assert_equal 3, snapshot_count, "must not collapse distinct same-day movements"
    assert_equal 3, entry_count
  end

  test "rotation re-keys both entries that share a transaction id" do
    a = rotating_tx("old_a", amount: "10.00").merge(transaction_id: "old_shared")
    b = rotating_tx("old_b", amount: "20.00").merge(transaction_id: "old_shared")
    sync_and_process([ a, b ])

    entries_by_amount = @account.entries.where(source: "enable_banking").pluck(:amount, :id).to_h
    assert_equal 2, entries_by_amount.size

    new_a = rotating_tx("new_a", amount: "10.00").merge(transaction_id: "new_shared")
    new_b = rotating_tx("new_b", amount: "20.00").merge(transaction_id: "new_shared")
    sync_and_process([ new_b, new_a ])

    assert_equal 2, snapshot_count
    assert_equal 2, entry_count
    assert_equal entries_by_amount, @account.entries.where(source: "enable_banking").pluck(:amount, :id).to_h
    assert_equal "ref_new_a", Entry.find(entries_by_amount.fetch(BigDecimal("10.00"))).transaction.provider_entry_reference
    assert_equal "ref_new_b", Entry.find(entries_by_amount.fetch(BigDecimal("20.00"))).transaction.provider_entry_reference
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

  test "a truncated pagination run does not evict rows it never covered" do
    sync([ rotating_tx("aaa", amount: "10.00"), rotating_tx("unfetched", amount: "20.00") ])
    assert_equal 2, snapshot_count

    # The ASPSP repeats its continuation_key, so fetch_paginated_transactions
    # returns the pages it did get and reports the fetch as truncated.
    @importer.unstub(:fetch_paginated_transactions)
    @provider.stubs(:get_account_transactions)
             .returns({ transactions: [ rotating_tx("bbb", amount: "10.00") ], continuation_key: "k1" })
             .then.returns({ transactions: [], continuation_key: "k1" })

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    stored = @enable_banking_account.reload.raw_transactions_payload.map { |t| t.with_indifferent_access[:transaction_id] }
    assert_equal %w[txn_bbb txn_unfetched], stored.sort
  end

  test "a truncated fetch from a rotating ASPSP re-keys the rows it did return" do
    sync_and_process([ rotating_tx("aaa", amount: "10.00"), rotating_tx("unfetched", amount: "20.00") ])
    assert_equal 2, entry_count

    sync_and_process([ rotating_tx("bbb", amount: "10.00") ], truncated: true)
    assert_equal 2, entry_count
    assert_equal 2, snapshot_count

    sync_and_process([ rotating_tx("ccc", amount: "10.00"), rotating_tx("unfetched2", amount: "20.00") ])
    assert_equal 2, entry_count
    assert_equal 2, snapshot_count
  end

  test "a window the ASPSP shortened only supersedes rows inside it" do
    older = [ 20, 10 ].map { |days| rotating_tx("old#{days}", date: days.days.ago.to_date.to_s, amount: "#{days}.00") }
    @enable_banking_account.upsert_enable_banking_transactions_snapshot!(older)

    sync([ rotating_tx("fresh") ], window_start: 5.days.ago.to_date)

    stored = @enable_banking_account.raw_transactions_payload.map { |t| t.with_indifferent_access[:transaction_id] }
    assert_equal %w[txn_fresh txn_old10 txn_old20], stored.sort
  end

  test "a sync that read a snapshot another sync since replaced does not write" do
    sync_and_process([ rotating_tx("aaa") ])
    stale_account = EnableBankingAccount.find(@enable_banking_account.id)

    sync_and_process([ rotating_tx("bbb") ])
    sync([ rotating_tx("ccc") ], account: stale_account)
    process

    assert_equal [ "txn_bbb" ], @enable_banking_account.raw_transactions_payload.map { |t| t.with_indifferent_access[:transaction_id] }
    assert_equal 1, entry_count
  end

  test "an empty first fetch does not overwrite a snapshot another sync stored" do
    stale_account = EnableBankingAccount.find(@enable_banking_account.id)
    assert_nil stale_account.raw_transactions_payload

    sync([ rotating_tx("aaa") ])
    sync([], account: stale_account)

    assert_equal [ "txn_aaa" ], @enable_banking_account.raw_transactions_payload.map { |t| t.with_indifferent_access[:transaction_id] }
  end

  test "an unchanged response does not rewrite the snapshot" do
    sync([ rotating_tx("aaa") ])

    @enable_banking_account.expects(:upsert_enable_banking_transactions_snapshot!).never
    sync([ rotating_tx("aaa") ])
    assert_equal 1, snapshot_count
  end

  test "rotating pending rows are carried over with pending sync on" do
    @importer.stubs(:include_pending?).returns(true)
    pending_tx = ->(nonce) { rotating_tx(nonce, amount: "42.00", counterparty: "Hold Co").merge(status: "PDNG") }

    sync_and_process([ rotating_tx("book_a") ], pending: [ pending_tx.("pend_a") ])
    assert_equal 2, entry_count

    sync_and_process([ rotating_tx("book_b") ], pending: [ pending_tx.("pend_b") ])
    assert_equal 2, entry_count
    assert_equal 2, snapshot_count
  end

  test "window dates are resolved in the family's timezone" do
    @family.update!(timezone: "Pacific/Auckland")
    late_utc = Time.utc(2026, 10, 3, 12, 30)
    rows = [
      { transaction_id: "iso", booking_date: late_utc.iso8601 },
      { transaction_id: "epoch", booking_date: late_utc.to_i }
    ]

    kept = @importer.send(:filter_transactions_by_date, rows, Date.new(2026, 10, 4))

    assert_equal %w[iso epoch], kept.map { |tx| tx[:transaction_id] }
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
