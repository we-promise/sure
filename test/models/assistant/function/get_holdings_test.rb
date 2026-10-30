require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetHoldings.new(@user)
    @account = accounts(:investment)
    @account.update!(cost_basis_method: "fifo")
    @security = Security.create!(ticker: "LOTG", name: "LOTG")
    Security::Price.insert_all((3.days.ago.to_date..Date.current).map { |date| { security_id: @security.id, date: date, price: 30, currency: "USD" } })
    # 60 at $12, then 40 at $20, then 40 sold: FIFO keeps 20 at $12 and 40 at
    # $20 ($17.33 a unit), where the pooled average is $15.20.
    @first_buy = create_trade(@security, account: @account, qty: 60, price: 12, date: 3.days.ago.to_date)
    @second_buy = create_trade(@security, account: @account, qty: 40, price: 20, date: 2.days.ago.to_date)
    create_trade(@security, account: @account, qty: -40, price: 25, date: 1.day.ago.to_date)
    Holding::Materializer.new(@account.reload, strategy: :forward, security_ids: [ @security.id ]).materialize_holdings
    @holding = @account.holdings.find_by!(security: @security, date: Date.current)
  end

  # With no stored cost the figure is the fallback, which on a FIFO account
  # reads the open lots; the assistant must answer what the drawer shows.
  test "get_holdings average_cost equals the drawer figure" do
    @holding.update_columns(cost_basis: nil, cost_basis_source: nil)
    drawer = Holding.find(@holding.id).avg_cost

    row = lot_row

    assert_in_delta BigDecimal("17.3333"), drawer.amount, BigDecimal("0.0001"), "precondition: the drawer reads the open lots"
    assert_equal drawer.amount.to_f, row[:average_cost]
    assert_equal drawer.format, row[:formatted_average_cost]
  end

  test "get_holdings lists a position's open lots, oldest first" do
    lots = lot_row[:lots]

    assert_equal [ @first_buy.date, @second_buy.date ], lots.map { |lot| lot[:acquired_on] }
    assert_equal [ 20.0, 40.0 ], lots.map { |lot| lot[:quantity] }
    assert_equal [ 12.0, 20.0 ], lots.map { |lot| lot[:unit_cost] }
    assert_equal [ "$12.00", "$20.00" ], lots.map { |lot| lot[:formatted_unit_cost] }
    assert_equal [ false, false ], lots.map { |lot| lot[:opening] }
  end

  test "get_holdings gives no lots for a position its lots do not add up to" do
    @holding.update_columns(qty: @holding.qty + 1)

    row = lot_row
    assert row.key?(:lots)
    assert_nil row[:lots]
  end

  private

    def lot_row
      @fn.call("accounts" => [ @account.name ])[:holdings].find { |row| row[:ticker] == "LOTG" }
    end
end
