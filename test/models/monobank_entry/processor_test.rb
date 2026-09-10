require "test_helper"

class MonobankEntry::ProcessorTest < ActiveSupport::TestCase
  # 2026-01-09 12:00:00 UTC — mid-day so the date does not depend on the family zone.
  MIDDAY_UNIX = 1_767_960_000

  setup do
    @family = families(:empty)
    @family.update!(timezone: "Europe/Kyiv")
    @monobank_item = MonobankItem.create!(family: @family, name: "Test Monobank", access_token: "mono-token")
    @monobank_account = MonobankAccount.create!(
      monobank_item: @monobank_item,
      name: "Black card ·1234",
      account_id: "acc_1",
      currency: "UAH"
    )
    @account = Account.create!(
      family: @family,
      name: "Card",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "UAH"
    )

    AccountProvider.create!(account: @account, provider: @monobank_account)
  end

  test "imports a settled transaction with minor-unit and sign conversion" do
    entry = process(
      id: "tx_123",
      time: MIDDAY_UNIX,
      description: "Coffee Shop",
      mcc: 5812,
      originalMcc: 5812,
      hold: false,
      amount: -12_500,
      operationAmount: -12_500,
      currencyCode: 980,
      commissionRate: 0,
      cashbackAmount: 1_900,
      balance: 100_500_00,
      comment: "За каву",
      receiptId: "XXXX-XXXX-XXXX-XXXX"
    )

    assert_equal "monobank_tx_123", entry.external_id
    assert_equal "monobank", entry.source
    # Monobank reports -12500 kopiykas out; Sure stores an expense as positive 125.00.
    assert_equal BigDecimal("125"), entry.amount
    assert_equal "UAH", entry.currency
    assert_equal Date.new(2026, 1, 9), entry.date
    assert_equal "Coffee Shop", entry.name
    assert_equal "За каву", entry.notes
    assert_equal "Coffee Shop", entry.entryable.merchant.name

    extra = entry.entryable.extra["monobank"]
    assert_equal false, extra["pending"]
    assert_equal 5812, extra["mcc"]
    assert_equal "100500.0", extra["balance_after"].to_s
    assert_equal "19.0", extra["cashback_amount"].to_s
    assert_nil extra["operation_amount"], "no FX metadata when the amounts agree"
  end

  test "income keeps the inverted sign" do
    entry = process(id: "tx_in", time: MIDDAY_UNIX, description: "Зарплата", amount: 25_000_00, operationAmount: 25_000_00, currencyCode: 980, hold: false)

    assert_equal BigDecimal("-25000"), entry.amount
  end

  test "marks held transactions as pending" do
    entry = process(id: "tx_hold", time: MIDDAY_UNIX, description: "Pending auth", amount: -800, operationAmount: -800, currencyCode: 980, hold: true)

    assert entry.entryable.pending?
    assert_equal true, entry.entryable.extra.dig("monobank", "pending")
  end

  test "records the operation currency and amount for a foreign-currency purchase" do
    # A UAH card paying in EUR: `amount` is the UAH charge, `operationAmount` the EUR
    # figure, and `currencyCode` names the euro — not the account's hryvnia.
    entry = process(id: "tx_fx", time: MIDDAY_UNIX, description: "Steam", amount: -41_500, operationAmount: -1_000, currencyCode: 978, hold: false)

    assert_equal "UAH", entry.currency, "the entry stays in the account currency"
    assert_equal BigDecimal("415"), entry.amount

    extra = entry.entryable.extra["monobank"]
    assert_equal(-1_000, extra["operation_amount"])
    assert_equal "EUR", extra["fx_from"]
    assert_equal "-10.0", extra["fx_amount"]
  end

  test "does not treat an account-currency operation as foreign" do
    entry = process(id: "tx_local", time: MIDDAY_UNIX, description: "Silpo", amount: -41_500, operationAmount: -41_500, currencyCode: 980, hold: false)

    extra = entry.entryable.extra["monobank"]
    assert_equal "UAH", entry.currency
    assert_nil extra["fx_from"]
    assert_nil extra["fx_amount"]
    assert_nil extra["operation_amount"]
  end

  test "keeps the account currency when currencyCode names another one" do
    # The regression this replaces: 500 UAH leaving a hryvnia card to fund a euro card
    # was stored as 500 EUR, because `currencyCode` reports the operation currency.
    entry = process(id: "tx_transfer", time: MIDDAY_UNIX, description: "Card transfer", amount: -50_000, operationAmount: -960, currencyCode: 978, hold: false)

    assert_equal "UAH", entry.currency
    assert_equal BigDecimal("500"), entry.amount
    assert_equal "EUR", entry.entryable.extra.dig("monobank", "fx_from")
    assert_equal "-9.6", entry.entryable.extra.dig("monobank", "fx_amount")
  end

  test "captures a diagnostic when a foreign operation amount will not parse" do
    entry = nil

    assert_difference "DebugLogEntry.count", 1 do
      entry = process(id: "tx_bad_op", time: MIDDAY_UNIX, description: "Steam", amount: -41_500, operationAmount: "not-a-number", currencyCode: 978, hold: false)
    end

    extra = entry.entryable.extra["monobank"]
    assert_equal "EUR", extra["fx_from"], "the currency is still known"
    assert_nil extra["fx_amount"]

    log = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_error", log.category
    assert_equal "warn", log.level
    assert_equal "monobank", log.provider_key
    assert_equal "monobank_tx_bad_op", log.metadata["external_id"]
    assert_equal "EUR", log.metadata["operation_currency"]
  end

  test "leaves fx metadata unset when currencyCode is unrecognized" do
    entry = process(id: "tx_bad_cur", time: MIDDAY_UNIX, description: "Unknown", amount: -1_000, operationAmount: -500, currencyCode: 1, hold: false)

    extra = entry.entryable.extra["monobank"]
    assert_equal "UAH", entry.currency
    assert_nil extra["fx_from"]
    assert_nil extra["fx_amount"]
    assert_equal(-500, extra["operation_amount"], "the raw figure is still kept for reference")
  end

  test "stores counterparty details for business account transfers" do
    entry = process(
      id: "tx_fop",
      time: MIDDAY_UNIX,
      description: "ТОВ «ВОРОНА»",
      amount: 500_00,
      operationAmount: 500_00,
      currencyCode: 980,
      hold: false,
      counterEdrpou: "3096889974",
      counterIban: "UA-TEST-IBAN-COUNTERPARTY",
      counterName: "ТОВ «ВОРОНА»"
    )

    extra = entry.entryable.extra["monobank"]
    assert_equal "3096889974", extra["counter_edrpou"]
    assert_equal "UA-TEST-IBAN-COUNTERPARTY", extra["counter_iban"]
  end

  test "non-UAH accounts convert using their own minor units" do
    @monobank_account.update!(currency: "USD")
    @account.update!(currency: "USD")

    entry = process(id: "tx_usd", time: MIDDAY_UNIX, description: "Hosting", amount: -1_050, operationAmount: -1_050, currencyCode: 840, hold: false)

    assert_equal BigDecimal("10.5"), entry.amount
    assert_equal "USD", entry.currency
  end

  test "raises when the transaction has no timestamp" do
    assert_raises ArgumentError do
      process(id: "tx_no_time", description: "Broken", amount: -100, currencyCode: 980, hold: false)
    end
  end

  test "id-less transactions fall back to a content hash so they still deduplicate" do
    data = { "account_id" => "acc_1", "time" => MIDDAY_UNIX, "amount" => -100, "description" => "No id" }

    first = MonobankEntry::Processor.canonical_external_id(data)
    second = MonobankEntry::Processor.canonical_external_id(data.dup)

    assert_equal first, second
    assert first.start_with?("monobank_pending_")
  end

  private

    def process(**transaction_data)
      MonobankEntry::Processor.new(
        transaction_data.deep_stringify_keys,
        monobank_account: @monobank_account
      ).process
    end
end
