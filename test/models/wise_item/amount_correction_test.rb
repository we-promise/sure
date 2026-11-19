require "test_helper"

class WiseItem::AmountCorrectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = Account.create!(family: @family, name: "Wise EUR", balance: 0, currency: "EUR",
                               accountable: Depository.new(subtype: "checking"))
  end

  test "Wise's amount reaches an entry a person categorized, noted or excluded" do
    categorized = booked(user_modified: true)
    categorized.entryable.update!(locked_attributes: { "category_id" => Time.current.iso8601 })
    noted = booked(user_modified: true, notes: "Rent")
    excluded = booked(excluded: true)

    [ categorized, noted, excluded ].each do |entry|
      WiseItem::AmountCorrection.apply(entry, amount: BigDecimal("-115.4"), currency: "EUR")
      assert_equal [ BigDecimal("-115.4"), "EUR" ], entry.reload.values_at(:amount, :currency)
    end
    assert_equal "Rent", noted.notes
    assert excluded.excluded?
  end

  test "keeps the amount a person set, and that of entries an import, a reconciliation, a split or a transfer owns" do
    amount_locked = booked(user_modified: true, locked_attributes: { "amount" => Time.current.iso8601 })
    currency_locked = booked(user_modified: true, locked_attributes: { "currency" => Time.current.iso8601 })
    import_locked = booked(import_locked: true)
    reconciled = booked(user_modified: true, reconciled_at: Time.current)
    split = booked(user_modified: true)
    split.split!([ { name: "Groceries", amount: 60, category_id: nil }, { name: "Household", amount: 40, category_id: nil } ])
    in_transfer = booked(user_modified: true)
    bank = Account.create!(family: @family, name: "Bank", balance: 0, currency: "EUR", accountable: Depository.new(subtype: "checking"))
    deposit = bank.entries.create!(amount: -100, currency: "EUR", date: in_transfer.date, name: "From Wise", entryable: Transaction.new)
    Transfer.create!(inflow_transaction: deposit.entryable, outflow_transaction: in_transfer.entryable, status: "confirmed")

    [ amount_locked, currency_locked, import_locked, reconciled, split, in_transfer ].each do |entry|
      WiseItem::AmountCorrection.apply(entry.reload, amount: BigDecimal("80"), currency: "EUR")
      assert_equal BigDecimal("100"), entry.reload.amount, entry.name
    end
  end

  test "leaves an entry the adapter could update alone" do
    entry = booked
    assert_no_changes -> { entry.reload.updated_at } do
      WiseItem::AmountCorrection.apply(entry, amount: BigDecimal("80"), currency: "EUR")
    end
  end

  private

    def booked(**attributes)
      @account.entries.create!(external_id: "wise_transfer_#{SecureRandom.hex(4)}", source: "wise", amount: 100, currency: "EUR",
                               date: Date.current, name: "Payout", entryable: Transaction.new, **attributes)
    end
end
