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

  test "keeps transactions with identical name/amount/date but different counterparty iban" do
    transactions = [
      {
        entry_reference: "ref_landlord_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_landlord_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "AT611904300234573201" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "still deduplicates identical transactions when only one side has counterparty iban data" do
    # A pending row and its later booked settlement can be otherwise
    # identical but differ in whether the account data has arrived yet --
    # a blank IBAN on one side must not be treated as proof they're
    # different real transactions (see issue this regresses: a pending row
    # settling into its booked form would otherwise both survive and
    # double-count the balance). The richer (booked, IBAN-bearing) row is
    # kept, not just whichever one the API happened to list first.
    transactions = [
      {
        entry_reference: "ref_pending",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      },
      {
        entry_reference: "ref_booked",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_booked", result.first[:entry_reference]
  end

  test "still deduplicates identical transactions that share the same counterparty iban" do
    transactions = [
      {
        entry_reference: "ref_dup_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_dup_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
  end

  test "merges a pending row's iban into the booked representative that lost it" do
    # Some ASPSPs drop counterparty account data once a transaction settles
    # (the booked delivery has less detail than the earlier pending one).
    # Status still ranks above IBAN presence when picking the group's
    # representative (a still-pending row would otherwise get stuck pending
    # forever), but the IBAN itself must not be silently discarded either --
    # it's merged into the booked representative instead of being traded
    # away for it.
    transactions = [
      {
        entry_reference: "ref_pending_with_iban",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      },
      {
        entry_reference: "ref_booked_without_iban",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_booked_without_iban", result.first[:entry_reference],
      "the settled row must be kept, not the still-pending one"
    assert_equal "DE89370400440532013000", result.first.dig(:creditor_account, :iban), # pipelock:ignore IBAN
      "the booked representative must still gain the pending sibling's iban"
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

  test "deduplicates using value_date when booking_date is absent" do
    transactions = [
      {
        entry_reference: "ref_1",
        transaction_id: nil,
        value_date: "2026-02-10",
        transaction_amount: { amount: "1.50", currency: "EUR" },
        creditor: { name: "Waschsalon" },
        status: "BOOK"
      },
      {
        entry_reference: "ref_2",
        transaction_id: nil,
        value_date: "2026-02-10",
        transaction_amount: { amount: "1.50", currency: "EUR" },
        creditor: { name: "Waschsalon" },
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_1", result.first[:entry_reference]
  end

  test "keeps payment and same-day refund with same amount as separate transactions" do
    transactions = [
      {
        entry_reference: "ref_payment",
        transaction_id: nil,
        booking_date: "2026-02-09",
        transaction_amount: { amount: "25.00", currency: "EUR" },
        creditor: { name: "Amazon" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_refund",
        transaction_id: nil,
        booking_date: "2026-02-09",
        transaction_amount: { amount: "25.00", currency: "EUR" },
        creditor: { name: "Amazon" },
        credit_debit_indicator: "CRDT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "collapses a blank-iban duplicate into an existing bucket instead of forming a third transaction" do
    # A base-content group with two genuinely distinct counterparty IBANs
    # (a same-tx_id collision, per issue #954) plus a pending duplicate of
    # one of them that hasn't gained account data yet must still resolve
    # to 2 transactions -- not 3, which would happen if the blank-IBAN row
    # formed its own bucket instead of aliasing into one of the existing
    # IBAN buckets.
    transactions = [
      {
        entry_reference: "ref_a",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_b",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "AT611904300234573201" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_a_pending",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
  end

  test "a blank-iban row occupying a bucket first does not block the row that actually owns it" do
    # Same 3-row split-group shape as above, but the blank-IBAN row is
    # listed FIRST in the array, ahead of the row for the bucket it
    # aliases into. Naively keeping "whichever row is seen first" per key
    # would let the blank row claim that bucket and then discard the real,
    # IBAN-bearing row as a "duplicate" -- losing that transaction's actual
    # counterparty data (or, worse, an entirely different real transaction
    # if the API ever also reused the blank row's own entry_reference).
    transactions = [
      {
        entry_reference: "ref_a_pending",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      },
      {
        entry_reference: "ref_a",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "AT611904300234573201" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_b",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 2, result.count
    kept_refs = result.map { |tx| tx[:entry_reference] }
    assert_includes kept_refs, "ref_a"
    assert_includes kept_refs, "ref_b"
    assert_not_includes kept_refs, "ref_a_pending"
  end

  test "returns empty array for empty input" do
    result = @importer.send(:deduplicate_api_transactions, [])
    assert_equal [], result
  end
end
