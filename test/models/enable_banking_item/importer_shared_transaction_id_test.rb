require "test_helper"

# Enable Banking does not guarantee transaction_id to be unique. Rows that share
# one but carry different entry_references must stay separate entries, across
# syncs, without changing the id of an entry that already exists.
class EnableBankingItem::ImporterSharedTransactionIdTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: Date.new(2026, 3, 1)
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Compte courant",
      uid: "hash_shared_tid",
      account_id: "uuid-shared-tid",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: mock())
    @importer.stubs(:include_pending?).returns(false)
  end

  test "a sibling row arriving in a later sync is stored and imported as its own entry" do
    sync(booked: [ row("r-a", "9.00") ])
    legacy = entry!("enable_banking_tid-x")

    sync(booked: [ row("r-b", "7.00"), row("r-a", "9.00") ])

    assert_equal [ "r-a", "r-b" ], stored_refs
    assert_equal({ "enable_banking_tid-x" => BigDecimal("9.00"), sibling_id("r-b") => BigDecimal("7.00") }, amounts_by_id)
    assert_equal legacy.id, entry!("enable_banking_tid-x").id
  end

  test "re-fetching the rows in reverse order creates no entries and swaps no ids" do
    sync(booked: [ row("r-a", "9.00"), row("r-b", "7.00") ])
    before = @account.entries.where(source: "enable_banking").pluck(:id, :external_id, :amount).sort

    sync(booked: [ row("r-b", "7.00"), row("r-a", "9.00") ])

    assert_equal [ "r-a", "r-b" ], stored_refs
    assert_equal before, @account.entries.where(source: "enable_banking").pluck(:id, :external_id, :amount).sort
  end

  test "a pending row still settles into the entry under the legacy id" do
    @importer.stubs(:include_pending?).returns(true)

    sync(booked: [], pending: [ row("r-p", "9.00", status: "PDNG") ])
    pending_entry = entry!("enable_banking_tid-x")
    assert pending_entry.transaction.pending?

    sync(booked: [ row("r-a", "9.00"), row("r-b", "7.00") ], pending: [])

    assert_equal [ "r-a", "r-b" ], stored_refs
    assert_equal 2, @account.entries.where(source: "enable_banking").count
    assert_equal pending_entry.id, entry!("enable_banking_tid-x").id
    assert_not pending_entry.reload.transaction.pending?
    assert_equal BigDecimal("7.00"), entry!(sibling_id("r-b")).amount
  end

  test "a pending entry stays with its booked row when a same-amount sibling comes first" do
    @importer.stubs(:include_pending?).returns(true)
    sync(booked: [], pending: [ row("r-p", "7.00", status: "PDNG", date: 3.days.ago.to_date) ])
    pending_entry = entry!("enable_banking_tid-x")
    pending_entry.update!(notes: "dinner")

    sync(booked: [ row("r-a", "7.00", date: 2.days.ago.to_date), row("r-b", "7.00", date: 3.days.ago.to_date) ], pending: [])

    assert_equal [ [ "enable_banking_tid-x", 3.days.ago.to_date, "dinner" ], [ sibling_id("r-a"), 2.days.ago.to_date, nil ] ],
                 @account.entries.where(source: "enable_banking").order(:external_id).pluck(:external_id, :date, :notes)
    assert_not pending_entry.reload.transaction.pending?
  end

  test "a pending entry settles onto the booked sibling with its amount when the dates differ" do
    @importer.stubs(:include_pending?).returns(true)
    sync(booked: [], pending: [ row("r-p", "7.00", status: "PDNG", date: 5.days.ago.to_date) ])
    pending_entry = entry!("enable_banking_tid-x")

    sync(booked: [ row("r-a", "9.00"), row("r-b", "7.00") ], pending: [])

    assert_equal({ "enable_banking_tid-x" => BigDecimal("7.00"), sibling_id("r-a") => BigDecimal("9.00") }, amounts_by_id)
    assert_equal pending_entry.id, entry!("enable_banking_tid-x").id
  end

  private

    # date: inside the 30-day incremental window determine_sync_start_date uses.
    def row(entry_reference, amount, status: "BOOK", date: 3.days.ago.to_date)
      {
        transaction_id: "tid-x",
        entry_reference: entry_reference,
        booking_date: date.to_s,
        transaction_amount: { amount: amount, currency: "EUR" },
        creditor: { name: "Laundromat" },
        credit_debit_indicator: "DBIT",
        status: status
      }
    end

    def sync(booked:, pending: nil)
      @importer.stubs(:fetch_paginated_transactions)
               .with(@enable_banking_account, has_entries(transaction_status: "BOOK")).returns(booked)
      unless pending.nil?
        @importer.stubs(:fetch_paginated_transactions)
                 .with(@enable_banking_account, has_entries(transaction_status: "PDNG")).returns(pending)
      end

      assert @importer.send(:fetch_and_store_transactions, @enable_banking_account)[:success]
      EnableBankingAccount::Transactions::Processor.new(@enable_banking_account.reload).process
    end

    def sibling_id(entry_reference)
      "enable_banking_tid-x_#{Digest::MD5.hexdigest(entry_reference)}"
    end

    def stored_refs
      @enable_banking_account.reload.raw_transactions_payload.map { |tx| tx.with_indifferent_access[:entry_reference] }
    end

    def entry!(external_id)
      @account.entries.find_by!(source: "enable_banking", external_id: external_id)
    end

    def amounts_by_id
      @account.entries.where(source: "enable_banking").pluck(:external_id, :amount).to_h
    end
end
