require "test_helper"

# N26 (and other ASPSPs exposing ISO 20022 bank transaction codes through
# Enable Banking) emit *two* booked entries for a single card purchase:
# one from the cardholder's point of view (PMNT-CCRD-POSD) and one from the
# merchant's point of view (PMNT-MCRD-UPCT). Both carry status BOOK and their
# own entry_reference, so neither the pending->booked reconciliation nor the
# content-level dedup of #988 collapses them.
#
# The importer must drop the MCRD row of each pair before content dedup runs.
class EnableBankingItem::ImporterCardTwinTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )

    @account = accounts(:depository)
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Hauptkonto",
      uid: "hash_card_twin_test",
      account_id: "uuid-card-twin-1234",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    mock_provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: mock_provider)
  end

  test "stores only the customer-side row of a twin pair" do
    # The MCRD row is listed first on purpose. The content dedup keeps the first
    # row of a group and ignores bank_transaction_code, so if the twin discard
    # ran *after* it the merchant's row would be the survivor. Asserting on
    # which row reaches the snapshot pins both the wiring and the ordering.
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "BOOK"))
      .returns([ merchant_card_purchase(entry_reference: "ref_mcrd"), customer_card_purchase(entry_reference: "ref_ccrd") ])
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "PDNG"))
      .returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(Date.new(2026, 1, 1))

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
    assert_equal "ref_ccrd", @enable_banking_account.raw_transactions_payload.first["entry_reference"]
  end

  test "stores one row for a twin pair whose creditor names differ between the two views" do
    # This is the pair that survives content dedup today: creditor.name is part
    # of the content key, and the two rows spell the counterparty differently,
    # so both reach the append-only snapshot and are never removed again.
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "BOOK"))
      .returns([
        merchant_card_purchase(entry_reference: "ref_mcrd", creditor: { name: "ACME Mktp" }),
        customer_card_purchase(entry_reference: "ref_ccrd", creditor: { name: "ACME Mktp*K4T9QX2" })
      ])
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "PDNG"))
      .returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(Date.new(2026, 1, 1))

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
    assert_equal "ref_ccrd", @enable_banking_account.raw_transactions_payload.first["entry_reference"]
  end

  test "stores an unpaired merchant-side row" do
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "BOOK"))
      .returns([ merchant_card_purchase(
        entry_reference: "ref_adjustment",
        bank_transaction_code: { code: "MCRD", sub_code: "DAJT", description: "PMNT" }
      ) ])
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "PDNG"))
      .returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(Date.new(2026, 1, 1))

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    @enable_banking_account.reload
    assert_equal 1, @enable_banking_account.raw_transactions_payload.count
    assert_equal "ref_adjustment", @enable_banking_account.raw_transactions_payload.first["entry_reference"]
  end

  test "records the discard in the debug log" do
    # Per the repo convention, support-relevant sync diagnostics belong in
    # DebugLogEntry so they show up in /settings/debug, not only in the raw log.
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "BOOK"))
      .returns([ merchant_card_purchase(entry_reference: "ref_mcrd"), customer_card_purchase(entry_reference: "ref_ccrd") ])
    @importer.stubs(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entry(transaction_status: "PDNG"))
      .returns([])
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:determine_sync_start_date).returns(Date.new(2026, 1, 1))

    assert_difference "DebugLogEntry.count", 1 do
      @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync", entry.category
    assert_equal "info", entry.level
    assert_equal "enable_banking", entry.provider_key
    assert_equal @account, entry.account
    assert_equal 1, entry.metadata["discarded_count"]
  end

  test "discards the merchant-side MCRD twin and keeps the customer-side CCRD" do
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd"),
      customer_card_purchase(entry_reference: "ref_ccrd")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 1, result.count
    assert_equal "ref_ccrd", result.first[:entry_reference]
  end

  test "keeps both purchases when two identical card purchases arrive as two twin pairs" do
    # Two purchases of the same amount at the same merchant on the same day.
    # The grouping key has no time component, so all four rows land in one
    # group. The rule is accounting-based: discard MCRD rows only down to the
    # number of CCRD rows, never "one row per group".
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd_1"),
      merchant_card_purchase(entry_reference: "ref_mcrd_2"),
      customer_card_purchase(entry_reference: "ref_ccrd_1"),
      customer_card_purchase(entry_reference: "ref_ccrd_2")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
    assert_equal [ "ref_ccrd_1", "ref_ccrd_2" ], result.map { |tx| tx[:entry_reference] }
  end

  test "discards only as many MCRD rows as there are CCRD rows in the group" do
    # One CCRD is missing (e.g. still pending upstream). Discarding both MCRD
    # rows would lose a real movement, so only one is dropped.
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd_1"),
      merchant_card_purchase(entry_reference: "ref_mcrd_2"),
      customer_card_purchase(entry_reference: "ref_ccrd_1")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
    assert_equal [ "ref_mcrd_2", "ref_ccrd_1" ], result.map { |tx| tx[:entry_reference] }
  end

  test "keeps an MCRD row that has no CCRD twin" do
    # MCRD/DAJT and MCRD/OTHR rows appear without a CCRD counterpart.
    # bank_transaction_code picks the survivor, it never matches on its own.
    transactions = [
      merchant_card_purchase(
        entry_reference: "ref_adjustment",
        bank_transaction_code: { code: "MCRD", sub_code: "DAJT", description: "PMNT" }
      )
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 1, result.count
    assert_equal "ref_adjustment", result.first[:entry_reference]
  end

  test "never merges two identical CCRD rows" do
    # Issue #2720: two legitimately distinct purchases with identical content.
    # This step must not touch them.
    transactions = [
      customer_card_purchase(entry_reference: "ref_ccrd_1"),
      customer_card_purchase(entry_reference: "ref_ccrd_2")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "keeps a booked MCRD row whose only CCRD counterpart is still pending" do
    # The discard runs on the booked and the pending rows together, after the
    # pending->booked reconciliation has had its say. That reconciliation cannot
    # pair these two - the twins carry different entry_references and different
    # fingerprints - so a pending CCRD and a booked MCRD can reach this step in
    # the same group. Discarding the booked row there would leave the movement
    # represented by a pending row only, and it disappears from the snapshot
    # entirely on an account that does not store pendings.
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd"),
      customer_card_purchase(entry_reference: "ref_ccrd", _pending: true)
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "discards the pending MCRD twin of a pending CCRD row" do
    # Twins that are both still pending pair normally.
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd", _pending: true),
      customer_card_purchase(entry_reference: "ref_ccrd", _pending: true)
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 1, result.count
    assert_equal "ref_ccrd", result.first[:entry_reference]
  end

  test "pairs twins whose creditor names differ between the merchant and customer views" do
    # The two rows spell the counterparty differently: case-only changes
    # (Coffee Bar / COFFEE BAR), an extra order token on the cardholder's row
    # (ACME Mktp / ACME Mktp*K4T9QX2) or character substitutions
    # (B&B Store 0334 / B_B Store 0334). creditor.name must stay out of the key.
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd", creditor: { name: "ACME Mktp" }),
      customer_card_purchase(entry_reference: "ref_ccrd", creditor: { name: "ACME Mktp*K4T9QX2" })
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 1, result.count
    assert_equal "ref_ccrd", result.first[:entry_reference]
  end

  test "keeps an MCRD row whose amount differs from the CCRD row" do
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd", transaction_amount: { amount: "12.00", currency: "EUR" }),
      customer_card_purchase(entry_reference: "ref_ccrd")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "keeps an MCRD row whose booking_date differs from the CCRD row" do
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd", booking_date: "2026-02-12"),
      customer_card_purchase(entry_reference: "ref_ccrd")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "keeps a refund that mirrors a purchase of the same amount on the same day" do
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd", credit_debit_indicator: "CRDT"),
      customer_card_purchase(entry_reference: "ref_ccrd")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "leaves transfers and direct debits untouched" do
    transactions = [
      customer_card_purchase(
        entry_reference: "ref_transfer",
        bank_transaction_code: { code: "RCDT", sub_code: "ESCT", description: "PMNT" }
      ),
      customer_card_purchase(
        entry_reference: "ref_debit",
        bank_transaction_code: { code: "IDDT", sub_code: "ESDD", description: "PMNT" }
      )
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "leaves rows without a bank_transaction_code untouched" do
    transactions = [
      customer_card_purchase(entry_reference: "ref_no_code", bank_transaction_code: nil),
      customer_card_purchase(entry_reference: "ref_ccrd")
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 2, result.count
  end

  test "handles string keys in transaction data" do
    transactions = [
      merchant_card_purchase(entry_reference: "ref_mcrd").deep_stringify_keys,
      customer_card_purchase(entry_reference: "ref_ccrd").deep_stringify_keys
    ]

    result = @importer.send(:discard_merchant_card_twins, transactions, @enable_banking_account)

    assert_equal 1, result.count
    assert_equal "ref_ccrd", result.first["entry_reference"]
  end

  test "returns empty array for empty input" do
    assert_equal [], @importer.send(:discard_merchant_card_twins, [], @enable_banking_account)
  end

  private
    # A single card purchase, as an ASPSP that double-books reports it.
    def card_purchase(overrides)
      {
        entry_reference: "ref",
        transaction_id: nil,
        booking_date: "2026-02-11",
        value_date: "2026-02-11",
        transaction_amount: { amount: "5.12", currency: "EUR" },
        credit_debit_indicator: "DBIT",
        status: "BOOK",
        creditor: { name: "Corner Store" }
      }.merge(overrides)
    end

    def merchant_card_purchase(overrides = {})
      card_purchase(
        { bank_transaction_code: { code: "MCRD", sub_code: "UPCT", description: "PMNT" } }.merge(overrides)
      )
    end

    def customer_card_purchase(overrides = {})
      card_purchase(
        { bank_transaction_code: { code: "CCRD", sub_code: "POSD", description: "PMNT" } }.merge(overrides)
      )
    end
end
