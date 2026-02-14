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

  test "returns empty array for empty input" do
    result = @importer.send(:deduplicate_api_transactions, [])
    assert_equal [], result
  end
end
