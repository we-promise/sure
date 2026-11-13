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
    assert_equal({ "enable_banking_tid-x" => BigDecimal("9.00"), "enable_banking_tid-x_r-b" => BigDecimal("7.00") }, amounts_by_id)
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
    assert_equal BigDecimal("7.00"), entry!("enable_banking_tid-x_r-b").amount
  end

  test "external_ids_for leaves rows without a shared transaction_id on compute_external_id" do
    rows = [
      { entry_reference: "ref-1", booking_date: "2026-03-05", transaction_amount: { amount: "1.00", currency: "EUR" } },
      { booking_date: "2026-03-05", transaction_amount: { amount: "2.00", currency: "EUR" }, remittance_information: [ "X" ] },
      { transaction_id: "tid-y", entry_reference: "ref-2", booking_date: "2026-03-05", transaction_amount: { amount: "3.00", currency: "EUR" } },
      { transaction_id: "tid-z", booking_date: "2026-03-05", transaction_amount: { amount: "4.00", currency: "EUR" } },
      { transaction_id: "tid-z", booking_date: "2026-03-05", transaction_amount: { amount: "5.00", currency: "EUR" } }
    ]

    assert_equal rows.map { |r| EnableBankingEntry::Processor.compute_external_id(r) },
                 EnableBankingEntry::Processor.external_ids_for(rows)
  end

  private

    def row(entry_reference, amount, status: "BOOK")
      {
        transaction_id: "tid-x",
        entry_reference: entry_reference,
        # Inside the 30-day incremental window determine_sync_start_date uses.
        booking_date: 3.days.ago.to_date.to_s,
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
