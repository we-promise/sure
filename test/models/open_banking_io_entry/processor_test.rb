require "test_helper"

class OpenBankingIoEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://api.open-banking.io",
      api_key: "test-api-key",
      private_key: "test-private-key"
    )
    @provider_account = OpenBankingIoAccount.create!(
      open_banking_io_item: @item,
      name: "Test Bank - Everyday",
      account_id: "acc_123",
      currency: "EUR"
    )
    @account = Account.create!(
      family: @family,
      name: "Everyday",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "EUR"
    )

    AccountProvider.create!(account: @account, provider: @provider_account)
  end

  def process(overrides = {})
    txn = {
      id: "tx_123",
      currency: "EUR",
      credit_debit_indicator: "DBIT",
      status: "BOOK",
      booking_date: "2026-01-15",
      value_date: "2026-01-16",
      amount: "12.50",
      creditor_name: "Coffee Shop",
      debtor_name: "Jane Doe",
      remittance_information: "Latte"
    }.merge(overrides)

    OpenBankingIoEntry::Processor.new(txn, open_banking_io_account: @provider_account).process
  end

  # === SIGN (load-bearing) ===
  # open-banking.io reports an UNSIGNED magnitude. Sure stores expenses POSITIVE, income NEGATIVE.
  test "DBIT (money out) becomes a POSITIVE amount" do
    entry = process(credit_debit_indicator: "DBIT", amount: "12.50")
    assert_equal BigDecimal("12.5"), entry.amount
  end

  test "CRDT (money in) becomes a NEGATIVE amount" do
    entry = process(credit_debit_indicator: "CRDT", amount: "50.00")
    assert_equal BigDecimal("-50"), entry.amount
  end

  test "a DBIT magnitude that is already signed is normalised to POSITIVE" do
    entry = process(credit_debit_indicator: "DBIT", amount: "-12.50")
    assert_equal BigDecimal("12.5"), entry.amount
  end

  # === IDENTITY / DEDUP ===
  test "external_id is namespaced and source is open_banking_io" do
    entry = process
    assert_equal "open_banking_io_tx_123", entry.external_id
    assert_equal "open_banking_io", entry.source
  end

  test "re-processing the same transaction id de-duplicates on external_id + source" do
    first = process
    assert_difference -> { @account.entries.count }, 0 do
      second = process
      assert_equal first.id, second.id
    end
    assert_equal 1, @account.entries.where(external_id: "open_banking_io_tx_123", source: "open_banking_io").count
  end

  # === PENDING ===
  test "booked status is not pending" do
    entry = process(status: "BOOK")
    assert_equal false, entry.entryable.pending?
    assert_equal false, entry.entryable.extra.dig("open_banking_io", "pending")
  end

  test "a pending status marks the transaction pending under the provider key" do
    %w[PDNG PENDING HOLD].each do |status|
      entry = process(id: "tx_pending_#{status}", status: status)
      assert entry.entryable.pending?, "#{status} should be pending"
      assert_equal true, entry.entryable.extra.dig("open_banking_io", "pending")
    end
  end

  # The service treats BOOK, OTHR and an omitted status as booked
  # (BankingSyncService.NonBookedStatuses). Banks that never stamp a status -- PayPal DE,
  # Belfius BE, BPER Banca -- send none at all. Classifying those as pending made every
  # transaction eligible for the stale-pending prune, which destroys the entry and every
  # user edit on it. Unknown must mean booked.
  test "OTHR, a blank status and an omitted status are all booked, not pending" do
    [ "OTHR", "", nil ].each_with_index do |status, i|
      entry = process(id: "tx_booked_#{i}", status: status)
      assert_not entry.entryable.pending?, "#{status.inspect} should not be pending"
      assert_equal false, entry.entryable.extra.dig("open_banking_io", "pending")
    end
  end

  test "status matching ignores case and surrounding whitespace" do
    assert OpenBankingIoEntry::Processor.pending?(status: " pdng ")
    assert_not OpenBankingIoEntry::Processor.pending?(status: " book ")
  end

  # === SKIPPED STATUSES ===
  # Cancelled and rejected entries are money that never moved; scheduled ones have not
  # happened yet. None of them belong in the ledger.
  test "cancelled, rejected and scheduled entries are flagged for skipping" do
    %w[CNCL RJCT SCHD].each do |status|
      assert OpenBankingIoEntry::Processor.skip?(status: status), "#{status} should be skipped"
    end
  end

  test "booked and pending entries are not flagged for skipping" do
    %w[BOOK OTHR PDNG HOLD].each do |status|
      assert_not OpenBankingIoEntry::Processor.skip?(status: status), "#{status} should not be skipped"
    end
    assert_not OpenBankingIoEntry::Processor.skip?(status: nil)
  end

  # === NAME ===
  test "DBIT uses the creditor name" do
    entry = process(credit_debit_indicator: "DBIT", creditor_name: "Coffee Shop", debtor_name: "Jane Doe")
    assert_equal "Coffee Shop", entry.name
  end

  test "CRDT uses the debtor name" do
    entry = process(credit_debit_indicator: "CRDT", creditor_name: "Coffee Shop", debtor_name: "Employer Ltd")
    assert_equal "Employer Ltd", entry.name
  end

  test "falls back to remittance information when the counterparty is missing" do
    entry = process(creditor_name: nil, debtor_name: nil, remittance_information: "Card payment 1234")
    assert_equal "Card payment 1234", entry.name
  end

  # === DATE ===
  test "prefers booking_date and falls back to value_date then transaction_date" do
    entry = process(booking_date: nil, value_date: "2026-02-01")
    assert_equal Date.new(2026, 2, 1), entry.date

    entry = process(id: "tx_txndate", booking_date: nil, value_date: nil, transaction_date: "2026-03-03")
    assert_equal Date.new(2026, 3, 3), entry.date
  end

  test "skips a transaction with no usable date" do
    result = process(booking_date: nil, value_date: nil, transaction_date: nil)
    assert_nil result
  end

  # === CURRENCY ===
  test "uses the transaction currency and falls back to the account currency" do
    entry = process(currency: "GBP")
    assert_equal "GBP", entry.currency

    entry = process(id: "tx_nocur", currency: nil)
    assert_equal "EUR", entry.currency
  end

  # === CREDIT/DEBIT INDICATOR GUARD (Fix 4) ===
  # An unknown indicator must never be guessed as credit (income) — the transaction
  # is skipped so a garbled feed can't silently flip an expense into income.
  test "skips a transaction with a blank credit_debit_indicator instead of importing it as income" do
    result = process(id: "tx_blank", credit_debit_indicator: "")
    assert_nil result
    assert_not @account.entries.exists?(external_id: "open_banking_io_tx_blank")
  end

  test "skips a transaction with a garbage credit_debit_indicator" do
    result = process(id: "tx_garbage", credit_debit_indicator: "XYZ")
    assert_nil result
    assert_not @account.entries.exists?(external_id: "open_banking_io_tx_garbage")
  end

  test "accepts CRDT and DBIT case-insensitively" do
    assert_not_nil process(id: "tx_lc_dbit", credit_debit_indicator: "dbit")
    assert_not_nil process(id: "tx_lc_crdt", credit_debit_indicator: "crdt")
  end

  # === ID-LESS FINGERPRINT (Fixes 2 & 4) ===
  # Two id-less CRDT transfers that are identical except for the counterparty
  # (debtor_name) must fingerprint differently, otherwise one collides with the
  # other and is silently dropped on import.
  test "id-less transfers differing only by debtor_name get distinct external_ids" do
    base = {
      status: "BOOK",
      credit_debit_indicator: "CRDT",
      amount: "50.00",
      currency: "EUR",
      booking_date: "2026-03-01",
      remittance_information: "Rent"
    }

    id_a = OpenBankingIoEntry::Processor.canonical_external_id(base.merge(debtor_name: "Alice"))
    id_b = OpenBankingIoEntry::Processor.canonical_external_id(base.merge(debtor_name: "Bob"))

    assert_not_equal id_a, id_b
  end

  test "id-less transfers differing only by reference_number or bank_transaction_code get distinct external_ids" do
    base = {
      status: "BOOK",
      credit_debit_indicator: "CRDT",
      amount: "50.00",
      currency: "EUR",
      booking_date: "2026-03-01",
      debtor_name: "Alice"
    }

    id_ref_a = OpenBankingIoEntry::Processor.canonical_external_id(base.merge(reference_number: "REF-1"))
    id_ref_b = OpenBankingIoEntry::Processor.canonical_external_id(base.merge(reference_number: "REF-2"))
    assert_not_equal id_ref_a, id_ref_b

    id_code_a = OpenBankingIoEntry::Processor.canonical_external_id(base.merge(bank_transaction_code: "PMNT-RCDT"))
    id_code_b = OpenBankingIoEntry::Processor.canonical_external_id(base.merge(bank_transaction_code: "PMNT-ICDT"))
    assert_not_equal id_code_a, id_code_b
  end

  # Two id-less CRDT transfers identical except for the debtor must BOTH import
  # (distinct external_ids), rather than one overwriting the other.
  test "two id-less credit transfers differing only by debtor are both imported" do
    common = {
      status: "BOOK",
      credit_debit_indicator: "CRDT",
      amount: "50.00",
      currency: "EUR",
      booking_date: "2026-03-01",
      remittance_information: "Rent"
    }

    assert_not_nil process(common.merge(id: nil, debtor_name: "Alice"))
    assert_not_nil process(common.merge(id: nil, debtor_name: "Bob"))

    assert_equal 2, @account.entries.where("external_id LIKE ?", "open_banking_io_pending_%").count
  end

  # === COUNTERPARTY IDENTIFIERS AND FX ===
  # These arrive inside the decrypted envelope and used to be dropped on the floor by
  # Provider::OpenBankingIo#transaction_hash before the entry processor ever saw them.
  test "carries counterparty identifiers into the provider extra" do
    entry = process(
      id: "tx_ids",
      creditor_iban: "DK5000400440116243", creditor_bban: "00400440116243", creditor_agent_bic: "NDEADKKK",
      debtor_iban: "DK9520000123456789", debtor_bban: "20000123456789", debtor_agent_bic: "NYKBDKKK",
      reference_number_schema: "SCOR"
    )
    obio = entry.entryable.extra["open_banking_io"]

    assert_equal "DK5000400440116243", obio["creditor_iban"]
    assert_equal "00400440116243", obio["creditor_bban"]
    assert_equal "NDEADKKK", obio["creditor_agent_bic"]
    assert_equal "DK9520000123456789", obio["debtor_iban"]
    assert_equal "NYKBDKKK", obio["debtor_agent_bic"]
    assert_equal "SCOR", obio["reference_number_schema"]
  end

  test "records FX metadata when the instructed currency differs from the account currency" do
    entry = process(
      id: "tx_fx", currency: "EUR", amount: "92.10",
      instructed_amount: "100.00", instructed_currency: "USD", exchange_rate: "0.921",
      value_date: "2026-01-16", booking_date: "2026-01-18"
    )
    obio = entry.entryable.extra["open_banking_io"]

    assert_equal "USD", obio["fx_from"]
    assert_equal "100.00", obio["fx_amount"]
    assert_equal "0.921", obio["fx_rate"]
    # value_date, not booking_date: the rate applied when the money moved.
    assert_equal "2026-01-16", obio["fx_date"]
  end

  test "omits FX metadata for a same-currency transaction" do
    entry = process(id: "tx_nofx", currency: "EUR", instructed_currency: "EUR", instructed_amount: "12.50")
    obio = entry.entryable.extra["open_banking_io"]

    assert_nil obio["fx_from"]
    assert_nil obio["fx_amount"]
  end

  test "omits FX metadata when the provider sends no instructed currency" do
    entry = process(id: "tx_plain")
    assert_nil entry.entryable.extra["open_banking_io"]["fx_from"]
  end

  # A missing amount must fail the row rather than importing it as 0.00.
  test "raises rather than importing a transaction with no amount" do
    assert_raises(ArgumentError) { process(id: "tx_noamount", amount: nil) }
  end

  # === MERCHANTS ===
  # open_banking_io was registered as a ProviderMerchant source but nothing ever created
  # one, so the enum entry was inert while Up and Enable Banking both populate theirs.
  test "creates a provider merchant from the creditor name on a debit" do
    entry = process(id: "tx_merchant", credit_debit_indicator: "DBIT", creditor_name: "Netto")

    merchant = entry.entryable.merchant
    assert merchant
    assert_equal "Netto", merchant.name
    assert_equal "open_banking_io", merchant.source
  end

  test "reuses one merchant across case variations of the same name" do
    process(id: "tx_m1", credit_debit_indicator: "DBIT", creditor_name: "Netto")

    assert_no_difference "ProviderMerchant.count" do
      process(id: "tx_m2", credit_debit_indicator: "DBIT", creditor_name: "NETTO")
    end
  end

  # On a credit the counterparty is the payer -- an employer, a friend -- not a merchant.
  test "does not create a merchant for a credit" do
    assert_no_difference "ProviderMerchant.count" do
      entry = process(id: "tx_credit", credit_debit_indicator: "CRDT", debtor_name: "Employer Ltd")
      assert_nil entry.entryable.merchant
    end
  end

  # Remittance is free text -- invoice numbers, references, one-off descriptions. Minting a
  # merchant per distinct string fills provider_merchants with noise and makes the merchant
  # filter useless, so a missing counterparty means no merchant.
  test "does not invent a merchant from free-text remittance" do
    assert_no_difference "ProviderMerchant.count" do
      entry = process(id: "tx_rem", credit_debit_indicator: "DBIT", creditor_name: nil,
                      remittance_information: "Invoice 2026-00417")
      assert_nil entry.entryable.merchant
    end
  end

  test "ignores technical placeholder counterparties" do
    assert_no_difference "ProviderMerchant.count" do
      [ "CARD-8842", "POS 1188", "ATM-0091" ].each_with_index do |name, i|
        entry = process(id: "tx_tech_#{i}", credit_debit_indicator: "DBIT", creditor_name: name)
        assert_nil entry.entryable.merchant, name
      end
    end
  end
end
