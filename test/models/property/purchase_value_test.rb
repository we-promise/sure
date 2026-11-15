require "test_helper"

class Property::PurchaseValueTest < ActiveSupport::TestCase
  setup do
    @account = families(:dylan_family).accounts.create!(
      name: "Land", balance: 0, currency: "EUR", status: "draft", owner: users(:family_admin),
      accountable: Property.new(subtype: "plot")
    )
  end

  test "defaults the date to today on a draft without values" do
    assert_equal Date.current, Property::PurchaseValue.new(@account).date
  end

  test "defaults the date to the day before a value the draft already has" do
    add_reconciliation(date: 5.years.ago.to_date, amount: 90_000)

    assert_equal 5.years.ago.to_date.prev_day, Property::PurchaseValue.new(@account).default_date
  end

  test "uses a submitted date over the default" do
    assert_equal Date.new(2020, 3, 1), Property::PurchaseValue.new(@account, date: "2020-03-01").date
  end

  test "accepts dates from the day after the oldest supported date to today" do
    assert Property::PurchaseValue.new(@account, date: (Entry.min_supported_date + 1).iso8601).valid_date?
    assert Property::PurchaseValue.new(@account, date: Date.current.iso8601).valid_date?
    assert_not Property::PurchaseValue.new(@account, date: Entry.min_supported_date.iso8601).valid_date?
    assert_not Property::PurchaseValue.new(@account, date: Date.tomorrow.iso8601).valid_date?
    assert_not Property::PurchaseValue.new(@account, date: "not a date").valid_date?
  end

  test "rejects a submitted date that is not a string the parser accepts" do
    # A JSON body can send a number or a boolean, and the date parser rejects
    # strings over 128 characters with a plain ArgumentError.
    [ 20200301, 1.5, true, "2020-03-01#{" " * 119}" ].each do |submitted|
      assert_not Property::PurchaseValue.new(@account, date: submitted).valid_date?, submitted.inspect
    end
  end

  test "saving dates the purchase valuation and sets the balance" do
    @account.update!(currency: "PYG")

    result = Property::PurchaseValue.new(@account, date: 3.years.ago.to_date.iso8601).save(150_000_000)

    assert result.success?
    valuation = @account.entries.valuations.sole
    assert_equal 3.years.ago.to_date, valuation.date
    assert_equal 150_000_000, valuation.amount
    assert_equal "PYG", valuation.currency
    assert_equal 150_000_000, @account.reload.balance
  end

  test "saving a date on or after the draft's other values fails without writing" do
    add_reconciliation(date: 1.year.ago.to_date, amount: 90_000)

    result = Property::PurchaseValue.new(@account, date: Date.current.iso8601).save(100_000)

    assert_not result.success?
    assert_equal "Opening balance date must be before the oldest entry date", result.error
    assert_not @account.has_opening_anchor?
  end

  test "the price is the saved purchase valuation, not the latest value" do
    Property::PurchaseValue.new(@account, date: 2.years.ago.to_date.iso8601).save(100_000)
    add_reconciliation(date: Date.current, amount: 250_000)
    @account.update!(balance: 250_000)

    assert_equal 100_000, Property::PurchaseValue.new(@account).price
  end

  private
    def add_reconciliation(date:, amount:)
      @account.entries.create!(
        date: date, name: "Manual value update", amount: amount, currency: @account.currency,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end
end
