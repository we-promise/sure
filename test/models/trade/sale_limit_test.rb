require "test_helper"

class Trade::SaleLimitTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = families(:empty).accounts.create!(
      name: "Brokerage",
      balance: 10_000,
      cash_balance: 10_000,
      currency: "USD",
      accountable: Investment.new
    )
    @security = Security.create!(ticker: "SLTEST", name: "Sale Limit Test")
  end

  test "allows a sale up to the quantity held" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)

    sale = build_sale(qty: 10, date: Date.current)

    assert Trade::SaleLimit.new(sale).validate
    assert_empty sale.errors
  end

  test "blocks a sale larger than the quantity held and names what is available" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)

    sale = build_sale(qty: 12, date: Date.current)
    limit = Trade::SaleLimit.new(sale)

    assert_not limit.validate
    assert_equal 10, limit.available_qty
    assert_includes sale.errors.full_messages.to_sentence, "holds only 10"
  end

  test "blocks a sale of a security the account never held" do
    sale = build_sale(qty: 1, date: Date.current)

    assert_not Trade::SaleLimit.new(sale).validate
  end

  test "a back-dated sale may not push a later day below zero" do
    create_trade(@security, account: @account, qty: 10, date: 10.days.ago.to_date, price: 100)
    create_trade(@security, account: @account, qty: -8, date: 2.days.ago.to_date, price: 100)

    # Ten are held on the sale date, but only two are left after the later sale.
    too_many = build_sale(qty: 5, date: 5.days.ago.to_date)
    assert_not Trade::SaleLimit.new(too_many).validate
    assert_includes too_many.errors.full_messages.to_sentence, "at most 2"

    assert Trade::SaleLimit.new(build_sale(qty: 2, date: 5.days.ago.to_date)).validate
  end

  test "counts a split the way the holdings do" do
    create_trade(@security, account: @account, qty: 10, date: 10.days.ago.to_date, price: 100)
    Security::Split.create!(security: @security, ex_date: 5.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")

    assert Trade::SaleLimit.new(build_sale(qty: 20, date: Date.current)).validate
    assert_not Trade::SaleLimit.new(build_sale(qty: 21, date: Date.current)).validate
  end

  test "an edited sale is checked without its own earlier quantity" do
    create_trade(@security, account: @account, qty: 10, date: 10.days.ago.to_date, price: 100)
    sale = create_trade(@security, account: @account, qty: -4, date: 2.days.ago.to_date, price: 100)

    sale.entryable.qty = -10
    assert Trade::SaleLimit.new(sale).validate

    sale.entryable.qty = -11
    assert_not Trade::SaleLimit.new(sale).validate
  end

  test "making an oversold sale smaller is not blocked" do
    create_trade(@security, account: @account, qty: 5, date: 10.days.ago.to_date, price: 100)
    # Imported data can already be oversold; editing it down must stay possible.
    sale = create_trade(@security, account: @account, qty: -8, date: 2.days.ago.to_date, price: 100)

    sale.entryable.qty = -7
    assert Trade::SaleLimit.new(sale).validate

    sale.reload
    sale.notes = "checked"
    assert Trade::SaleLimit.new(sale).validate
  end

  test "moving a sale to another date is checked again" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)
    sale = create_trade(@security, account: @account, qty: -10, date: 2.days.ago.to_date, price: 100)

    sale.date = 8.days.ago.to_date

    assert_not Trade::SaleLimit.new(sale).validate
  end

  test "turning a buy into a sale is checked" do
    buy = create_trade(@security, account: @account, qty: 3, date: 2.days.ago.to_date, price: 100)

    buy.entryable.qty = -3

    assert_not Trade::SaleLimit.new(buy).validate
  end

  test "units moved out under any label are checked, not only sales" do
    %w[Transfer Sweep\ Out].each do |label|
      outflow = build_sale(qty: 5, date: Date.current)
      outflow.entryable.investment_activity_label = label

      assert_not Trade::SaleLimit.new(outflow).validate, label
    end
  end

  test "a back-dated sale before a split is compared in the units of its date" do
    create_trade(@security, account: @account, qty: 10, date: 10.days.ago.to_date, price: 100)
    Security::Split.create!(security: @security, ex_date: 5.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_trade(@security, account: @account, qty: -16, date: 2.days.ago.to_date, price: 50)

    # 20 after the split minus 16 leaves 4, which is 2 in pre-split units.
    assert Trade::SaleLimit.new(build_sale(qty: 2, date: 7.days.ago.to_date)).validate
    assert_not Trade::SaleLimit.new(build_sale(qty: 3, date: 7.days.ago.to_date)).validate
  end

  test "two future-dated sales cannot count the same units" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)
    create_trade(@security, account: @account, qty: -10, date: 1.day.from_now.to_date, price: 100)

    assert_not Trade::SaleLimit.new(build_sale(qty: 10, date: 2.days.from_now.to_date)).validate
    # Today's sale is limited by tomorrow's: only what tomorrow leaves over may go.
    assert_not Trade::SaleLimit.new(build_sale(qty: 1, date: Date.current)).validate
  end

  test "a future-dated purchase covers a sale dated after it" do
    create_trade(@security, account: @account, qty: 4, date: 2.days.from_now.to_date, price: 100)

    assert Trade::SaleLimit.new(build_sale(qty: 4, date: 3.days.from_now.to_date)).validate
    assert_not Trade::SaleLimit.new(build_sale(qty: 4, date: 1.day.from_now.to_date)).validate
  end

  test "save! locks the account for a sale and raises when refused" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)
    @account.expects(:lock!).once

    assert_raises(ActiveRecord::RecordInvalid) { Trade::SaleLimit.save!(build_sale(qty: 11, date: Date.current)) }
  end

  test "save! takes no lock for an entry the limit does not apply to" do
    @account.expects(:lock!).never

    Trade::SaleLimit.save!(create_trade(@security, account: @account, qty: 3, date: 2.days.ago.to_date, price: 100).tap { |e| e.notes = "x" })
  end

  test "linked accounts never refuse a sale, because the provider's holdings stay the truth" do
    # A sale recorded on a linked account only raises the days before it, so it
    # cannot take any day below zero, even when the provider already shows 0.
    @account.stubs(:linked?).returns(true)

    assert Trade::SaleLimit.new(build_sale(qty: 10, date: Date.current)).validate
  end

  test "save checks under an account lock and writes nothing when refused" do
    create_trade(@security, account: @account, qty: 10, date: 5.days.ago.to_date, price: 100)
    @account.expects(:lock!).twice

    assert Trade::SaleLimit.save(build_sale(qty: 6, date: Date.current))
    assert_no_difference "Entry.count" do
      assert_not Trade::SaleLimit.save(build_sale(qty: 6, date: Date.current))
    end
  end

  private
    def build_sale(qty:, date:)
      @account.entries.new(
        name: "Sell",
        date: date,
        amount: -qty * 100,
        currency: "USD",
        entryable: Trade.new(
          security: @security,
          qty: -qty,
          price: 100,
          currency: "USD",
          investment_activity_label: "Sell"
        )
      )
    end
end
