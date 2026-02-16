require "test_helper"

class EnableBankingItem::ImporterDedupTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "AT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )

    mock_provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: mock_provider)
  end

  test "removes content-level duplicates with different entry_reference IDs" do
    transactions = [
      {
        entry_reference: "ref_aaa",
        transaction_id: nil,
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar Dankt 3418" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_bbb",
        transaction_id: nil,
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar Dankt 3418" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_aaa", result.first[:entry_reference]
  end

  test "keeps transactions with different amounts" do
    transactions = [
      {
        entry_reference: "ref_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "23.30", currency: "EUR" },
        creditor: { name: "Spar" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "keeps transactions with different dates" do
    transactions = [
      {
        entry_reference: "ref_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        booking_date: "2026-02-08",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "keeps transactions with different creditors" do
    transactions = [
      {
        entry_reference: "ref_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Lidl" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "removes multiple duplicates from same response" do
    base = {
      booking_date: "2026-02-07",
      transaction_amount: { amount: "3.00", currency: "EUR" },
      creditor: { name: "Bakery" },
      status: "BOOK"
    }

    transactions = [
      base.merge(entry_reference: "ref_1"),
      base.merge(entry_reference: "ref_2"),
      base.merge(entry_reference: "ref_3")
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_1", result.first[:entry_reference]
  end

  test "handles string keys in transaction data" do
    transactions = [
      {
        "entry_reference" => "ref_aaa",
        "booking_date" => "2026-02-07",
        "transaction_amount" => { "amount" => "11.65", "currency" => "EUR" },
        "creditor" => { "name" => "Spar" },
        "status" => "BOOK"
      },
      {
        "entry_reference" => "ref_bbb",
        "booking_date" => "2026-02-07",
        "transaction_amount" => { "amount" => "11.65", "currency" => "EUR" },
        "creditor" => { "name" => "Spar" },
        "status" => "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
  end

  test "differentiates by remittance_information" do
    transactions = [
      {
        entry_reference: "ref_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "100.00", currency: "EUR" },
        creditor: { name: "Landlord" },
        remittance_information: [ "Rent January" ],
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "100.00", currency: "EUR" },
        creditor: { name: "Landlord" },
        remittance_information: [ "Rent February" ],
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "handles nil values in remittance_information array" do
    transactions = [
      {
        entry_reference: "ref_aaa",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar" },
        remittance_information: [ nil, "Payment ref 123", nil ],
        status: "BOOK"
      },
      {
        entry_reference: "ref_bbb",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "11.65", currency: "EUR" },
        creditor: { name: "Spar" },
        remittance_information: [ "Payment ref 123", nil ],
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_aaa", result.first[:entry_reference]
  end

  test "preserves distinct transactions with same content but different transaction_ids" do
    transactions = [
      {
        entry_reference: "ref_1",
        transaction_id: "txn_001",
        booking_date: "2026-02-09",
        transaction_amount: { amount: "1.50", currency: "EUR" },
        creditor: { name: "Waschsalon" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        transaction_id: "txn_002",
        booking_date: "2026-02-09",
        transaction_amount: { amount: "1.50", currency: "EUR" },
        creditor: { name: "Waschsalon" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "deduplicates same transaction_id even with different entry_references" do
    transactions = [
      {
        entry_reference: "ref_aaa",
        transaction_id: "txn_same",
        booking_date: "2026-02-09",
        transaction_amount: { amount: "25.00", currency: "EUR" },
        creditor: { name: "Amazon" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_bbb",
        transaction_id: "txn_same",
        booking_date: "2026-02-09",
        transaction_amount: { amount: "25.00", currency: "EUR" },
        creditor: { name: "Amazon" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_aaa", result.first[:entry_reference]
  end

  test "preserves transactions with same non-unique transaction_id but different content" do
    # Per Enable Banking API docs, transaction_id is not guaranteed to be unique.
    # Two transactions sharing a transaction_id but differing in content must both be kept.
    transactions = [
      {
        entry_reference: "ref_1",
        transaction_id: "shared_tid",
        booking_date: "2026-02-09",
        transaction_amount: { amount: "25.00", currency: "EUR" },
        creditor: { name: "Amazon" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        transaction_id: "shared_tid",
        booking_date: "2026-02-09",
        transaction_amount: { amount: "42.00", currency: "EUR" },
        creditor: { name: "Amazon" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "returns empty array for empty input" do
    result = @importer.send(:deduplicate_api_transactions, [])
    assert_equal [], result
  end
end
