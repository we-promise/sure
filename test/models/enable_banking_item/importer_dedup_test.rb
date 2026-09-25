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

  test "still deduplicates identical transactions whose counterparty iban differs only in punctuation" do
    transactions = [
      {
        entry_reference: "ref_dup_punct_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_dup_punct_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account: { iban: "de89.3704-0044/0532:0130'00" },
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

  test "merges a pending row's additional_identification and agent into the booked representative when neither has an iban" do
    # A donor row that only carries the additional_identification fallback
    # (no IBAN at all) must still be picked up -- the old donor search only
    # matched on IBAN presence, so a row like this was silently ignored and
    # EnableBankingEntry::Processor never saw the fallback counterparty_account_id
    # or bank name it would otherwise have used.
    transactions = [
      {
        entry_reference: "ref_pending_with_additional_id",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        creditor_account_additional_identification: { identification: "landlord-ref-123" },
        creditor_agent: { name: "Sparkasse" },
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      },
      {
        entry_reference: "ref_booked_without_any_counterparty_data",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 1, result.count
    assert_equal "ref_booked_without_any_counterparty_data", result.first[:entry_reference],
      "the settled row must be kept, not the still-pending one"
    assert_equal "landlord-ref-123", result.first.dig(:creditor_account_additional_identification, :identification),
      "the booked representative must gain the pending sibling's additional_identification fallback"
    assert_equal "Sparkasse", result.first.dig(:creditor_agent, :name),
      "the booked representative must gain the pending sibling's bank name"
  end

  test "does not merge an ambiguous blank-iban row into either of two distinct-iban transactions" do
    # Three rows share the same content pattern (date/amount/creditor/etc.),
    # but two of them carry different, distinct IBANs -- proof this content
    # pattern really does correspond to (at least) two separate real
    # transactions, not one duplicated delivery. The third row has no IBAN
    # at all, so it's genuinely unknown which of the two (or neither) it
    # belongs to. Picking one by, say, alphabetical IBAN order would risk
    # attributing a status/data update to the wrong transaction (or, if it's
    # actually a third distinct payee, silently dropping it) -- so it must
    # end up as its own separate result, not merged into either bucket.
    transactions = [
      {
        entry_reference: "ref_a_book",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        creditor_account: { iban: "AT611904300234573201" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_b_pending",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      },
      {
        entry_reference: "ref_ambiguous_no_iban",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 3, result.count, "all three rows must survive as distinct results"
    by_ref = result.index_by { |tx| tx[:entry_reference] }
    assert_equal "BOOK", by_ref["ref_a_book"][:status]
    assert_equal "AT611904300234573201", by_ref["ref_a_book"].dig(:creditor_account, :iban) # pipelock:ignore IBAN
    assert_equal "PDNG", by_ref["ref_b_pending"][:status],
      "the ambiguous row must not have been silently merged into this transaction's status"
    assert_equal "DE89370400440532013000", by_ref["ref_b_pending"].dig(:creditor_account, :iban) # pipelock:ignore IBAN
    assert_equal "BOOK", by_ref["ref_ambiguous_no_iban"][:status]
    assert_nil by_ref["ref_ambiguous_no_iban"].dig(:creditor_account, :iban)
  end

  test "collapses two ambiguous blank-iban rows into each other, but still apart from the known-iban buckets" do
    # Multiple rows that are ALL blank on IBAN, within a group that also has
    # two distinct known IBANs, can't be told apart from each other either --
    # but unlike merging into a KNOWN-different counterparty, merging them
    # with each other loses nothing (they're indistinguishable anyway).
    transactions = [
      {
        entry_reference: "ref_a_book",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        creditor_account: { iban: "AT611904300234573201" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_b_book",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        creditor_account: { iban: "DE89370400440532013000" }, # pipelock:ignore IBAN
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      },
      {
        entry_reference: "ref_ambiguous_1",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      },
      {
        entry_reference: "ref_ambiguous_2",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "50.00", currency: "EUR" },
        creditor: { name: "Same Payee" },
        credit_debit_indicator: "DBIT",
        status: "BOOK"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 3, result.count, "the two ambiguous rows must collapse into one, alongside the two known-iban transactions"
    by_ref = result.index_by { |tx| tx[:entry_reference] }
    assert_equal "AT611904300234573201", by_ref["ref_a_book"].dig(:creditor_account, :iban) # pipelock:ignore IBAN
    assert_equal "DE89370400440532013000", by_ref["ref_b_book"].dig(:creditor_account, :iban) # pipelock:ignore IBAN
    assert_equal "ref_ambiguous_2", result.map { |tx| tx[:entry_reference] }.find { |ref| ref.start_with?("ref_ambiguous") },
      "the booked ambiguous row must be the kept representative, not the still-pending one"
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

  test "keeps a blank-iban row apart from an existing bucket it cannot be attributed to" do
    # A base-content group with two genuinely distinct counterparty IBANs
    # (a same-tx_id collision, per issue #954) plus a row that hasn't gained
    # account data yet resolves to 3 transactions, not 2: aliasing the
    # blank-IBAN row into one of the two known-IBAN buckets would be a
    # guess that can silently attribute (or fail to attribute) a status
    # update to the wrong real transaction. See the "ambiguous" bucket in
    # #deduplicate_api_transactions.
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
        entry_reference: "ref_ambiguous",
        transaction_id: "shared_tid",
        booking_date: "2026-02-07",
        transaction_amount: { amount: "850.00", currency: "EUR" },
        creditor: { name: "Miete" },
        credit_debit_indicator: "DBIT",
        status: "PDNG"
      }
    ]

    result = @importer.send(:deduplicate_api_transactions, transactions)

    assert_equal 3, result.count
    kept_refs = result.map { |tx| tx[:entry_reference] }
    assert_includes kept_refs, "ref_a"
    assert_includes kept_refs, "ref_b"
    assert_includes kept_refs, "ref_ambiguous"
  end

  test "a blank-iban row occupying a bucket first does not block the row that actually owns it" do
    # Same 3-row split-group shape as above, but the blank-IBAN row is
    # listed FIRST in the array, ahead of the two known-IBAN rows. This
    # must not affect which rows end up representing which bucket --
    # ref_a and ref_b must keep their own IBAN data regardless of array
    # order, and the blank row must still end up on its own.
    transactions = [
      {
        entry_reference: "ref_ambiguous",
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

    assert_equal 3, result.count
    kept_refs = result.map { |tx| tx[:entry_reference] }
    assert_includes kept_refs, "ref_ambiguous"
    assert_includes kept_refs, "ref_a"
    assert_includes kept_refs, "ref_b"
  end

  test "returns empty array for empty input" do
    result = @importer.send(:deduplicate_api_transactions, [])
    assert_equal [], result
  end
end
