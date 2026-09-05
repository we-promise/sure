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

  # The operation currency is not reported by Monobank, so only the raw operation amount
  # is recorded — fx_from/fx_amount are deliberately left unset.
  test "records the operation amount for a foreign-currency purchase" do
    entry = process(id: "tx_fx", time: MIDDAY_UNIX, description: "Steam", amount: -41_500, operationAmount: -1_000, currencyCode: 980, hold: false)

    extra = entry.entryable.extra["monobank"]
    assert_equal(-1_000, extra["operation_amount"])
    assert_nil extra["fx_from"]
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
