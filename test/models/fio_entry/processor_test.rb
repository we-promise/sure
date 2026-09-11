require "test_helper"

class FioEntry::ProcessorTest < ActiveSupport::TestCase
  # 2026-06-15 00:00:00 +02:00 — Prague midnight, the shape Fio serialises a booking day
  # as. Deliberately not mid-day: a naive reading in a western timezone lands on the 14th.
  PRAGUE_MIDNIGHT_MS = 1_781_474_400_000

  setup do
    @family = families(:empty)
    @family.update!(timezone: "America/New_York")
    @fio_item = FioItem.create!(family: @family, name: "Test Fio", token: "fio-token")
    @fio_account = FioAccount.create!(
      fio_item: @fio_item,
      name: "Fio banka 2400222222",
      fio_account_id: "2400222222",
      currency: "CZK"
    )
    @account = Account.create!(
      family: @family,
      name: "Fio",
      accountable: Depository.new(subtype: "checking"),
      balance: 1000,
      currency: "CZK"
    )

    AccountProvider.create!(account: @account, provider: @fio_account)
  end

  test "imports an outgoing transfer with Fio's sign convention flipped" do
    entry = process(
      id: 1_148_734_530,
      date: PRAGUE_MIDNIGHT_MS,
      amount: -450.5,
      currency: "CZK",
      counter_account_name: "Pavel, Novák",
      operation_type: "Platba převodem uvnitř banky"
    )

    assert_equal "fio_1148734530", entry.external_id
    assert_equal "fio", entry.source
    assert_equal 450.5, entry.amount
    assert_equal "Pavel, Novák", entry.name
    assert_equal Date.new(2026, 6, 15), entry.date
  end

  test "imports an incoming transfer as a credit" do
    entry = process(id: 1, date: PRAGUE_MIDNIGHT_MS, amount: 1_200.0, currency: "CZK")

    assert_equal(-1_200.0, entry.amount)
  end

  # Fio stamps a movement with its Prague banking day at local midnight. Reading it in
  # the family's zone would file every transaction a day early for anyone west of Prague.
  test "reads the booking day in Prague regardless of the family timezone" do
    entry = process(id: 2, date: PRAGUE_MIDNIGHT_MS, amount: -1.0)

    assert_equal Date.new(2026, 6, 15), entry.date
  end

  # A card payment has no counterparty; the acceptor arrives in "Uživatelská
  # identifikace" wrapped in Fio's own prefix and trailing location.
  test "names a card payment after the acceptor and records it as a merchant" do
    entry = process(
      id: 3,
      date: PRAGUE_MIDNIGHT_MS,
      amount: -239.0,
      user_identification: "Nákup: PENNY MARKET s.r.o., Jaromer, CZ",
      operation_type: "Platba kartou"
    )

    assert_equal "PENNY MARKET s.r.o.", entry.name
    assert_equal "PENNY MARKET s.r.o.", entry.entryable.merchant&.name
    assert_nil entry.notes
  end

  # The same field on a non-card movement is a free-text reference, not an acceptor, so
  # it must not be mangled into a merchant.
  test "does not derive a merchant from a transfer's user identification" do
    entry = process(
      id: 4,
      date: PRAGUE_MIDNIGHT_MS,
      amount: -100.0,
      user_identification: "Nákup: something, else, CZ",
      operation_type: "Bezhotovostní platba"
    )

    assert_nil entry.entryable.merchant
    assert_equal "Nákup: something, else, CZ", entry.name
  end

  test "falls back to the operation type when a movement has no counterparty or reference" do
    entry = process(id: 5, date: PRAGUE_MIDNIGHT_MS, amount: 0.02, operation_type: "Připsaný úrok")

    assert_equal "Připsaný úrok", entry.name
  end

  # "Upřesnění" carries the original amount of a converted card payment.
  test "records the foreign amount of a converted payment" do
    entry = process(
      id: 6,
      date: PRAGUE_MIDNIGHT_MS,
      amount: -397.5,
      currency: "CZK",
      specification: "15.90 EUR",
      user_identification: "Nákup: HOTEL WIEN, Wien, AT",
      operation_type: "Platba kartou"
    )

    assert_equal "EUR", entry.entryable.extra.dig("fio", "fx_from")
    assert_equal "15.9", entry.entryable.extra.dig("fio", "fx_amount")
  end

  test "ignores a specification that is not a foreign amount" do
    entry = process(id: 7, date: PRAGUE_MIDNIGHT_MS, amount: -1.0, specification: "Poplatek za vedení")

    assert_nil entry.entryable.extra.dig("fio", "fx_from")
  end

  test "keeps the payment reference in notes when it is not the name" do
    entry = process(
      id: 8,
      date: PRAGUE_MIDNIGHT_MS,
      amount: -300.0,
      counter_account_name: "Pavel, Novák",
      message: "Za obed",
      variable_symbol: "1234567890"
    )

    assert_equal "Pavel, Novák", entry.name
    assert_equal "Za obed", entry.notes
    assert_equal "1234567890", entry.entryable.extra.dig("fio", "variable_symbol")
  end

  test "joins the counterparty account with its bank code" do
    entry = process(
      id: 9,
      date: PRAGUE_MIDNIGHT_MS,
      amount: -50.0,
      counter_account: "2900233333",
      counter_bank_id: "2010"
    )

    assert_equal "2900233333/2010", entry.entryable.extra.dig("fio", "counter_account")
  end

  # Without an id there is nothing stable to deduplicate on, and a retry would double
  # the movement.
  test "skips a movement with no id" do
    assert_nil FioEntry::Processor.new(raw(date: PRAGUE_MIDNIGHT_MS, amount: -1.0), fio_account: @fio_account).process
    assert_nil FioEntry::Processor.canonical_external_id(raw(amount: -1.0))
  end

  test "reprocessing the same movement updates the entry it already produced" do
    movement = raw(id: 10, date: PRAGUE_MIDNIGHT_MS, amount: -100.0, counter_account_name: "First")
    first = FioEntry::Processor.new(movement, fio_account: @fio_account).process

    updated = raw(id: 10, date: PRAGUE_MIDNIGHT_MS, amount: -120.0, counter_account_name: "Second")
    second = FioEntry::Processor.new(updated, fio_account: @fio_account).process

    assert_equal first.id, second.id
    assert_equal 120.0, second.reload.amount
  end

  private

    # Builds a raw movement in Fio's numbered-column form.
    def raw(**fields)
      fields.each_with_object({}) do |(field, value), payload|
        column = FioEntry::Processor::COLUMNS.fetch(field)
        payload[column] = { "value" => value, "id" => column.delete_prefix("column").to_i }
      end
    end

    def process(**fields)
      FioEntry::Processor.new(raw(**fields), fio_account: @fio_account).process
    end
end
