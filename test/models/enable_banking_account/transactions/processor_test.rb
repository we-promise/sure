require "test_helper"

class EnableBankingAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family:              @family,
      name:                "Test EB Item",
      country_code:        "FR",
      application_id:      "app_id",
      client_certificate:  "cert"
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name:                "Compte courant",
      uid:                 "uid_txn_proc_test",
      currency:            "EUR",
      current_balance:     1000.00
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)
  end

  # Two id-less rows that share every hashed field and differ only in a note.
  def distinguishable_collision_rows
    base = {
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "100.00", "currency" => "EUR" },
      "credit_debit_indicator" => "CRDT",
      "status" => "BOOK"
    }
    [ base.merge("note" => "first transfer"), base.merge("note" => "second transfer") ]
  end

  # Minimal raw transaction payload hash matching the shape EnableBankingEntry::Processor expects
  def raw_pending_transaction(transaction_id:)
    {
      transaction_id:       transaction_id,
      value_date:           3.days.ago.to_date.to_s,
      transaction_amount:   { amount: "25.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      _pending:             true
    }
  end

  test "does not re-import a pending transaction whose external_id was manually merged" do
    pending_ext_id = "enable_banking_PDNG_MERGED"

    # Simulate a previously-merged state: a posted transaction carries the pending's external_id
    # in its manual_merge metadata, which is how merge_with_duplicate! records the merge.
    posted_entry = create_transaction(
      account:     @account,
      name:        "Coffee Shop",
      date:        1.day.ago.to_date,
      amount:      25,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_SETTLED",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: {
        "manual_merge" => {
          "merged_from_entry_id"    => SecureRandom.uuid,
          "merged_from_external_id" => pending_ext_id,
          "merged_at"               => Time.current.iso8601,
          "source"                  => "enable_banking"
        }
      }
    )
    posted_entry.mark_user_modified!

    # Raw payload contains the pending transaction that was already merged
    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_MERGED")
      ]
    )

    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "imports a pending transaction that has NOT been merged" do
    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_NEW_UNMERGED")
      ]
    )

    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "imports non-excluded transactions alongside excluded ones in the same batch" do
    pending_ext_id = "enable_banking_PDNG_SKIP_ME"

    posted_entry = create_transaction(
      account:     @account,
      name:        "Already Merged",
      date:        2.days.ago.to_date,
      amount:      15,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_ALREADY",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: {
        "manual_merge" => {
          "merged_from_external_id" => pending_ext_id,
          "merged_at"               => Time.current.iso8601,
          "source"                  => "enable_banking"
        }
      }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_SKIP_ME"),          # excluded
        raw_pending_transaction(transaction_id: "PDNG_BRAND_NEW_12345")   # should be imported
      ]
    )

    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "excludes all external_ids when multiple pending entries were merged into the same posted entry" do
    pending_ext_id_1 = "enable_banking_PDNG_MULTI_1"
    pending_ext_id_2 = "enable_banking_PDNG_MULTI_2"

    posted_entry = create_transaction(
      account:     @account,
      name:        "Multi Merge",
      date:        2.days.ago.to_date,
      amount:      30,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_MULTI",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: {
        "manual_merge" => [
          { "merged_from_external_id" => pending_ext_id_1, "merged_at" => 2.days.ago.iso8601, "source" => "enable_banking" },
          { "merged_from_external_id" => pending_ext_id_2, "merged_at" => 1.day.ago.iso8601,  "source" => "enable_banking" }
        ]
      }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_MULTI_1"),  # excluded
        raw_pending_transaction(transaction_id: "PDNG_MULTI_2"),  # excluded
        raw_pending_transaction(transaction_id: "PDNG_MULTI_NEW") # new — should import
      ]
    )

    result = nil
    assert_difference "@account.entries.count", 1 do
      result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    assert_equal 2, result[:skipped]
    assert_equal 1, result[:imported]
  end

  test "imports id-less transaction using content fingerprint" do
    tx = {
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "19.99", "currency" => "EUR" },
      "credit_debit_indicator" => "DBIT",
      "creditor" => { "name" => "Spotify" }
    }
    @enable_banking_account.update!(raw_transactions_payload: [ tx ])

    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end

    expected_id = EnableBankingEntry::Processor.compute_external_id(tx)
    assert @account.entries.exists?(external_id: expected_id, source: "enable_banking")
  end

  # An ASPSP that sends only date, amount, currency and direction makes two
  # same-day transfers of the same amount one content hash; the second used to
  # update the first and the account silently lost a transaction.
  test "imports two identical id-less rows from one batch as two transactions, once" do
    tx = {
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "100.00", "currency" => "EUR" },
      "credit_debit_indicator" => "CRDT",
      "status" => "BOOK"
    }
    @enable_banking_account.update!(raw_transactions_payload: [ tx, tx.dup ])

    assert_difference "@account.entries.count", 2 do
      result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
      assert_equal 2, result[:imported]
      assert_equal 0, result[:failed]
    end

    # The same response again adds nothing: both rows keep the ids they were given.
    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end

    ids = @account.entries.where(source: "enable_banking").pluck(:external_id)
    assert_includes ids, EnableBankingEntry::Processor.compute_external_id(tx), "the first keeps the bare hash"
    assert_includes ids, EnableBankingEntry::Processor.compute_external_id(tx, suffix: "1")
  end

  # Two rows can collide on every hashed field and still differ in one the hash
  # does not read. Each takes an id from its full content, so the next response
  # can order them as it likes.
  test "collision rows that differ in an unhashed field keep their identity when the response is reordered" do
    first, second = distinguishable_collision_rows

    @enable_banking_account.update!(raw_transactions_payload: [ first, second ])
    assert_difference "@account.entries.count", 2 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    before = @account.entries.where(source: "enable_banking").to_h { |e| [ e.external_id, e.notes ] }
    assert_equal 2, before.size
    assert_equal [ "first transfer", "second transfer" ], before.values.sort

    @enable_banking_account.update!(raw_transactions_payload: [ second, first ])
    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    after = @account.entries.where(source: "enable_banking").to_h { |e| [ e.external_id, e.notes ] }
    assert_equal before, after, "each row must keep the id it had, and so its note"
  end

  # A row once seen beside a twin may arrive alone in a later response. It is a
  # singleton then, but its full-content id is already in the ledger, so it
  # keeps that rather than taking the bare hash and becoming its twin.
  test "a collision row that later arrives alone keeps its identity" do
    first, second = distinguishable_collision_rows

    @enable_banking_account.update!(raw_transactions_payload: [ first, second ])
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    second_id = @account.entries.where(source: "enable_banking").find_by(notes: "second transfer").external_id

    @enable_banking_account.update!(raw_transactions_payload: [ second ])
    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end

    assert_equal second_id, @account.entries.where(source: "enable_banking").find_by(notes: "second transfer").external_id
    assert_equal "first transfer", @account.entries.where(source: "enable_banking").where.not(external_id: second_id).first.notes, "the first is untouched"
  end

  # Resolving identities before assigning them: the ledger says which member a
  # bare entry was made from, so a row first seen alone and later beside a
  # distinguishable twin keeps its id, and only the twin is new.
  test "a row first imported alone keeps its id when a distinguishable twin arrives" do
    first, second = distinguishable_collision_rows

    @enable_banking_account.update!(raw_transactions_payload: [ first ])
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    first_id = @account.entries.where(source: "enable_banking").sole.external_id
    assert_equal EnableBankingEntry::Processor.compute_external_id(first), first_id, "alone, it carries the bare hash"

    @enable_banking_account.update!(raw_transactions_payload: [ second, first ])
    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end

    by_note = @account.entries.where(source: "enable_banking").to_h { |e| [ e.notes, e.external_id ] }
    assert_equal first_id, by_note["first transfer"], "the first keeps the id it had"
    assert_not_equal first_id, by_note["second transfer"]
  end

  # The reverse transition: a group that was distinguishable is identical-only
  # next time. Its members still carry the ids they were given.
  test "members keep their ids when the group's shape changes between batches" do
    first, second = distinguishable_collision_rows

    @enable_banking_account.update!(raw_transactions_payload: [ first, first.dup, second ])
    assert_difference "@account.entries.count", 3 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    before = @account.entries.where(source: "enable_banking").pluck(:external_id).sort

    @enable_banking_account.update!(raw_transactions_payload: [ first, first.dup ])
    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    assert_equal before, @account.entries.where(source: "enable_banking").pluck(:external_id).sort
  end

  # A collision row the user merged away is excluded by its id. Arriving alone
  # later it must still be recognised as that id, or it comes back.
  test "a merged collision row that later arrives alone is still excluded" do
    first, second = distinguishable_collision_rows

    @enable_banking_account.update!(raw_transactions_payload: [ first, second ])
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    second_entry = @account.entries.where(source: "enable_banking").find_by(notes: "second transfer")
    second_id = second_entry.external_id

    # As merge_with_duplicate! leaves things: the merged entry is gone, and the
    # survivor records where it came from.
    survivor = @account.entries.where(source: "enable_banking").find_by(notes: "first transfer")
    survivor.transaction.update!(extra: { "manual_merge" => { "merged_from_external_id" => second_id, "merged_at" => Time.current.iso8601, "source" => "enable_banking" } })
    second_entry.destroy!

    @enable_banking_account.update!(raw_transactions_payload: [ second ])
    assert_no_difference "@account.entries.count" do
      result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
      assert_equal 1, result[:skipped]
    end
  end

  # A bare id already in the ledger with another row's fingerprint belongs to
  # that row. A newcomer arriving alone must not take it and overwrite it.
  test "a distinguishable row arriving alone does not overwrite the row that holds the bare id" do
    first, second = distinguishable_collision_rows

    @enable_banking_account.update!(raw_transactions_payload: [ first ])
    EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    first_entry = @account.entries.where(source: "enable_banking").sole

    @enable_banking_account.update!(raw_transactions_payload: [ second ])
    assert_difference "@account.entries.count", 1 do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end

    assert_equal "first transfer", first_entry.reload.notes, "the first keeps its own data"
    second_entry = @account.entries.where(source: "enable_banking").find_by(notes: "second transfer")
    assert second_entry
    assert_not_equal first_entry.external_id, second_entry.external_id
    assert second_entry.external_id.start_with?("#{first_entry.external_id}_")
  end

  test "id-less transaction does not appear in failed count" do
    tx = {
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "5.00", "currency" => "EUR" },
      "credit_debit_indicator" => "CRDT",
      "debtor" => { "name" => "Employer" }
    }
    @enable_banking_account.update!(raw_transactions_payload: [ tx ])

    result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process

    assert_equal 0, result[:failed]
  end

  test "does not re-import a pending transaction whose external_id was auto-claimed" do
    # When a pending entry is automatically matched to a booked transaction by the
    # amount/date heuristic (find_pending_transaction), the old pending external_id
    # is stored in auto_claimed_pending_ids so subsequent syncs don't recreate it.
    pending_ext_id = "enable_banking_PDNG_AUTO_CLAIMED"

    booked_entry = create_transaction(
      account:     @account,
      name:        "Grocery Store",
      date:        1.day.ago.to_date,
      amount:      55,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_SETTLED",
      source:      "enable_banking"
    )
    booked_entry.transaction.update!(
      extra: {
        "auto_claimed_pending_ids" => [ pending_ext_id ]
      }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_AUTO_CLAIMED")
      ]
    )

    assert_no_difference "@account.entries.count" do
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
  end

  test "does not re-import when both manual_merge and auto_claimed_pending_ids exclusions are present" do
    manually_merged_ext_id  = "enable_banking_PDNG_MANUAL"
    auto_claimed_ext_id     = "enable_banking_PDNG_AUTO"

    manual_entry = create_transaction(
      account:     @account,
      name:        "Manual Merge Entry",
      date:        2.days.ago.to_date,
      amount:      20,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_MANUAL",
      source:      "enable_banking"
    )
    manual_entry.transaction.update!(
      extra: {
        "manual_merge" => {
          "merged_from_external_id" => manually_merged_ext_id,
          "merged_at"               => Time.current.iso8601,
          "source"                  => "enable_banking"
        }
      }
    )

    auto_entry = create_transaction(
      account:     @account,
      name:        "Auto Claimed Entry",
      date:        1.day.ago.to_date,
      amount:      30,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_AUTO",
      source:      "enable_banking"
    )
    auto_entry.transaction.update!(
      extra: { "auto_claimed_pending_ids" => [ auto_claimed_ext_id ] }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_MANUAL"),         # excluded via manual_merge
        raw_pending_transaction(transaction_id: "PDNG_AUTO"),           # excluded via auto_claimed_pending_ids
        raw_pending_transaction(transaction_id: "PDNG_BRAND_NEW_XXXX")  # new — should import
      ]
    )

    result = nil
    assert_difference "@account.entries.count", 1 do
      result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process
    end
    assert_equal 2, result[:skipped]
    assert_equal 1, result[:imported]
  end

  test "handles empty raw_transactions_payload gracefully" do
    @enable_banking_account.update!(raw_transactions_payload: nil)

    result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process

    assert_equal true, result[:success]
    assert_equal 0, result[:total]
  end

  test "reports excluded transactions as skipped, not imported or failed" do
    pending_ext_id = "enable_banking_PDNG_SKIP_STATS"

    posted_entry = create_transaction(
      account:     @account,
      name:        "Stats Test",
      date:        2.days.ago.to_date,
      amount:      50,
      currency:    "EUR",
      external_id: "enable_banking_BOOK_STATS",
      source:      "enable_banking"
    )
    posted_entry.transaction.update!(
      extra: { "manual_merge" => { "merged_from_external_id" => pending_ext_id } }
    )

    @enable_banking_account.update!(
      raw_transactions_payload: [
        raw_pending_transaction(transaction_id: "PDNG_SKIP_STATS")
      ]
    )

    result = EnableBankingAccount::Transactions::Processor.new(@enable_banking_account).process

    assert_equal true, result[:success]
    assert_equal 1,    result[:skipped]
    assert_equal 0,    result[:imported]
    assert_equal 0,    result[:failed]
  end
end
