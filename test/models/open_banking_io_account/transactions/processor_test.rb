require "test_helper"

class OpenBankingIoAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
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
    AccountProvider.create!(account: @account, provider: @provider_account)
    @importer = OpenBankingIoItem::Importer.new(@item, open_banking_io_provider: nil)
  end

  def pending_txn(id:, amount: "25.00")
    {
      "id" => id,
      "status" => "PDNG",
      "credit_debit_indicator" => "DBIT",
      "amount" => amount,
      "booking_date" => 3.days.ago.to_date.to_s
    }
  end

  def process
    OpenBankingIoAccount::Transactions::Processor.new(@provider_account).process
  end

  # Fix 1(i): a pending transaction that later settles to booked under the SAME id
  # must end up booked (not stuck pending) with the amount/date updated — routed
  # through the real storage layer so the append-only bug is exercised.
  test "a pending transaction that settles under the same id ends up booked" do
    @importer.send(:store_transactions, @provider_account, transactions: [ pending_txn(id: "P", amount: "10.00") ])
    process

    entry = @account.entries.find_by!(external_id: "open_banking_io_P")
    assert entry.entryable.pending?, "expected first sync to create a pending entry"

    @importer.send(:store_transactions, @provider_account, transactions: [
      { "id" => "P", "status" => "BOOK", "credit_debit_indicator" => "DBIT", "amount" => "12.00", "booking_date" => 2.days.ago.to_date.to_s }
    ])
    process

    entry.reload
    assert_not entry.entryable.pending?, "expected the booked settlement to clear the pending flag"
    assert_equal BigDecimal("12.00"), entry.amount
    assert_equal 2.days.ago.to_date, entry.date
    assert_equal 1, @account.entries.where(source: "open_banking_io").count
  end

  # Fix 1(ii): a pending transaction auto-claimed by a booked sibling (different id)
  # must not be recreated as a phantom pending entry on the next sync.
  test "does not re-import a pending transaction whose external_id was auto-claimed" do
    booked_entry = create_transaction(
      account: @account, name: "Grocery", date: 1.day.ago.to_date, amount: 25,
      currency: "EUR", external_id: "open_banking_io_B", source: "open_banking_io"
    )
    booked_entry.transaction.update!(extra: { "auto_claimed_pending_ids" => [ "open_banking_io_A" ] })

    @provider_account.update!(raw_transactions_payload: [ pending_txn(id: "A") ])

    result = nil
    assert_no_difference "@account.entries.count" do
      result = process
    end
    assert_equal 1, result[:skipped]
  end

  # Fix 1: a pending transaction the user manually merged into a booked one must not
  # be re-imported either.
  test "does not re-import a pending transaction whose external_id was manually merged" do
    booked_entry = create_transaction(
      account: @account, name: "Coffee", date: 1.day.ago.to_date, amount: 25,
      currency: "EUR", external_id: "open_banking_io_BOOK", source: "open_banking_io"
    )
    booked_entry.transaction.update!(
      extra: { "manual_merge" => { "merged_from_external_id" => "open_banking_io_A", "source" => "open_banking_io" } }
    )
    booked_entry.mark_user_modified!

    @provider_account.update!(raw_transactions_payload: [ pending_txn(id: "A") ])

    assert_no_difference "@account.entries.count" do
      process
    end
  end

  # Bug 3: a booked transaction and its still-listed pending sibling (different
  # ids, same amount) arriving in the SAME fetch — with the booked row ordered
  # first (newest-first) — must reconcile to a SINGLE entry. The pending sibling
  # has to be processed before its booked settlement so the booked row can
  # auto-claim it, otherwise the pending row imports as a phantom duplicate.
  test "same-fetch booked and pending siblings reconcile to a single entry" do
    booked = { "id" => "B", "status" => "BOOK", "credit_debit_indicator" => "DBIT", "amount" => "25.00", "booking_date" => 1.day.ago.to_date.to_s }
    pending = { "id" => "A", "status" => "PDNG", "credit_debit_indicator" => "DBIT", "amount" => "25.00", "booking_date" => 2.days.ago.to_date.to_s }

    # Newest-first order: booked settlement (newer) precedes the pending sibling.
    @importer.send(:store_transactions, @provider_account, transactions: [ booked, pending ])
    process

    assert_equal 1, @account.entries.where(source: "open_banking_io").count,
      "expected the booked settlement to auto-claim its pending sibling, not double-count"

    entry = @account.entries.find_by(source: "open_banking_io")
    assert_not entry.entryable.pending?, "the surviving entry should be booked"
    assert_equal [ "open_banking_io_A" ], entry.transaction.extra["auto_claimed_pending_ids"]
  end

  # Bug 2: a pending authorization the bank stops returning (a canceled pre-auth
  # hold) must be stripped from the stored payload so its stale pending entry gets
  # pruned — instead of lingering in raw_transactions_payload forever and keeping
  # the phantom pending entry alive. Booked history absent from the window is kept.
  test "a pending row absent from the next fetch is pruned while booked history is kept" do
    booked = { "id" => "B", "status" => "BOOK", "credit_debit_indicator" => "DBIT", "amount" => "40.00", "booking_date" => 5.days.ago.to_date.to_s }
    @importer.send(:store_transactions, @provider_account, transactions: [ booked, pending_txn(id: "A") ])
    process
    assert @account.entries.exists?(external_id: "open_banking_io_A"), "sync 1 should import the pending entry"
    assert @account.entries.exists?(external_id: "open_banking_io_B"), "sync 1 should import the booked entry"

    # Sync 2: the canceled hold A is no longer returned; only a new, unrelated
    # pending row shows up. The older booked B is outside the window too.
    @importer.send(:store_transactions, @provider_account, transactions: [ pending_txn(id: "C", amount: "30.00") ])
    process

    assert_not @account.entries.exists?(external_id: "open_banking_io_A"), "canceled pending must be pruned, not left stuck pending"
    assert @account.entries.exists?(external_id: "open_banking_io_B"), "booked history must be retained"
    assert @account.entries.exists?(external_id: "open_banking_io_C"), "the new pending row must be imported"
  end

  # Fix 2: an id-less pending transaction must be imported (not dropped) with a
  # stable content-hash external_id.
  test "imports an id-less pending transaction with a stable content-hash external_id" do
    txn = {
      "status" => "PDNG", "credit_debit_indicator" => "DBIT", "amount" => "9.99",
      "booking_date" => Date.current.to_s, "creditor_name" => "Spotify",
      "remittance_information" => "Subscription"
    }
    @provider_account.update!(raw_transactions_payload: [ txn ])

    assert_difference "@account.entries.count", 1 do
      process
    end

    expected_id = OpenBankingIoEntry::Processor.canonical_external_id(txn)
    assert_match(/\Aopen_banking_io_pending_[0-9a-f]{32}\z/, expected_id)
    assert @account.entries.exists?(external_id: expected_id, source: "open_banking_io")
  end

  # === EMPTY-FETCH GUARD ===
  # A 200 with an empty items array is indistinguishable from "the bank dropped every
  # pending row". Treating it as the latter strips the rows from storage and destroys the
  # entries -- along with every category, merchant, note and split the user attached.
  test "an empty fetch does not strip stored pending rows" do
    @importer.send(:store_transactions, @provider_account, transactions: [ pending_txn(id: "P", amount: "10.00") ])
    process
    assert @account.entries.exists?(external_id: "open_banking_io_P")

    @importer.send(:store_transactions, @provider_account, transactions: [])

    assert_equal 1, @provider_account.reload.raw_transactions_payload.to_a.size,
                 "an empty fetch must not strip the stored pending row"
    process
    assert @account.entries.exists?(external_id: "open_banking_io_P"),
           "an empty fetch must not destroy a live pending entry"
  end

  test "a blank stored payload prunes nothing" do
    entry = create_transaction(
      account: @account, date: 2.days.ago.to_date, amount: 25,
      external_id: "open_banking_io_ORPHAN", source: "open_banking_io"
    )
    entry.entryable.update!(extra: { "open_banking_io" => { "pending" => true } })
    @provider_account.update!(raw_transactions_payload: [])

    result = process

    assert_equal 0, result[:pruned_pending]
    assert @account.entries.exists?(external_id: "open_banking_io_ORPHAN"),
           "a missing payload must never be read as an instruction to delete"
  end

  # A pending the bank never resolves is otherwise immortal: the keep-list protects it on
  # every sync, and its presence pins the lookback window open indefinitely.
  test "a pending far older than any real pre-auth is pruned even while still returned" do
    ancient = pending_txn(id: "OLD").merge("booking_date" => 90.days.ago.to_date.to_s)
    @importer.send(:store_transactions, @provider_account, transactions: [ ancient ])

    # The bank still returns it, so the keep-list would otherwise protect it forever.
    process
    process

    assert_not @account.entries.exists?(external_id: "open_banking_io_OLD"),
               "a pending older than MAX_PENDING_AGE must not survive on the keep-list"
  end

  test "a recent pending that is still returned is kept" do
    @importer.send(:store_transactions, @provider_account, transactions: [ pending_txn(id: "RECENT") ])
    process
    process

    assert @account.entries.exists?(external_id: "open_banking_io_RECENT")
  end

  # === SKIPPED STATUSES ===
  # A row imported while it was BOOK and later flipped to CNCL/RJCT must come back OUT.
  # Skipping alone would leave it in the ledger permanently, affecting the balance, with
  # no sync-driven path to remove it.
  test "an entry the bank later cancels is removed from the ledger" do
    booked = {
      "id" => "FLIP", "status" => "BOOK", "credit_debit_indicator" => "DBIT",
      "amount" => "99.00", "booking_date" => Date.current.to_s
    }
    @importer.send(:store_transactions, @provider_account, transactions: [ booked ])
    process
    assert @account.entries.exists?(external_id: "open_banking_io_FLIP")

    @importer.send(:store_transactions, @provider_account, transactions: [ booked.merge("status" => "CNCL") ])
    result = process

    assert_not @account.entries.exists?(external_id: "open_banking_io_FLIP"),
               "a cancelled transaction must not stay in the ledger"
    assert_operator result[:pruned_pending], :>=, 1
  end

  test "cancelled, rejected and scheduled entries are never imported" do
    @provider_account.update!(raw_transactions_payload: %w[CNCL RJCT SCHD].map do |status|
      {
        "id" => "tx_#{status}", "status" => status, "credit_debit_indicator" => "DBIT",
        "amount" => "42.00", "booking_date" => Date.current.to_s
      }
    end)

    assert_no_difference "@account.entries.count" do
      process
    end
  end

  # A bank that never stamps a status used to have its entire history classified pending,
  # which made every row a prune candidate as soon as it fell out of the sync window.
  test "status-less transactions are booked and survive a later narrow sync" do
    booked = {
      "id" => "NOSTATUS", "credit_debit_indicator" => "DBIT",
      "amount" => "15.00", "booking_date" => 90.days.ago.to_date.to_s
    }
    @importer.send(:store_transactions, @provider_account, transactions: [ booked ])
    process

    entry = @account.entries.find_by(external_id: "open_banking_io_NOSTATUS")
    assert entry, "a status-less transaction must be imported"
    assert_not entry.entryable.pending?

    # A later sync whose window excludes it must leave both the stored row and the entry alone.
    @importer.send(:store_transactions, @provider_account, transactions: [ pending_txn(id: "NEW") ])
    process

    assert @account.entries.exists?(external_id: "open_banking_io_NOSTATUS"),
           "booked history must never be pruned as though it were pending"
  end

  # With the corrected classifier most banks never produce a pending row, so "payload
  # present, zero pendings in it" is the normal case -- it must not destroy a recent
  # pending that simply has not auto-claimed yet.
  test "a fetch with no pending rows does not destroy a recent pending entry" do
    @importer.send(:store_transactions, @provider_account, transactions: [ pending_txn(id: "P") ])
    process
    assert @account.entries.exists?(external_id: "open_banking_io_P")

    booked_only = {
      "id" => "B", "status" => "BOOK", "credit_debit_indicator" => "DBIT",
      "amount" => "5.00", "booking_date" => Date.current.to_s
    }
    @provider_account.update!(raw_transactions_payload: [ booked_only ])
    process

    assert @account.entries.exists?(external_id: "open_banking_io_P"),
           "a recent pending must survive a booked-only fetch"
  end
end
