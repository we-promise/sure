require "test_helper"

class OpenBankingIoEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @item = OpenBankingIoItem.create!(
      family: @family,
      name: "Test open-banking.io",
      api_base_url: "https://api.example.com",
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

  test "non-booked status marks the transaction pending under the provider key" do
    entry = process(id: "tx_pending", status: "PNDG")
    assert entry.entryable.pending?
    assert_equal true, entry.entryable.extra.dig("open_banking_io", "pending")
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
end
