require "test_helper"

class TradeRepublicAccountHoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = trade_republic_items(:configured_item)
    @item.trade_republic_accounts.destroy_all

    @tr_account = @item.trade_republic_accounts.create!(
      name: "Holdings Test",
      trade_republic_account_id: "DEHOLD1",
      currency: "EUR"
    )
    @account = @family.accounts.create!(
      name: "Trade Republic Holdings Test",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    @tr_account.ensure_account_provider!(@account)
    @tr_account.reload
  end

  test "imports holding with fractional quantity and exact math" do
    import_position(isin: "US0378331005", quantity: "13.439945", price: "183.94", average_cost: "150.10")

    holding = @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US0378331005_#{Date.current}")

    assert_not_nil holding
    assert_equal BigDecimal("13.439945"), holding.qty
    assert_equal BigDecimal("13.439945").to_s, holding.qty.to_s
    assert_equal BigDecimal("183.94"), holding.price

    # qty keeps 8 fractional digits; the amount column stores scale-4
    # (Sure-wide convention), so compare against the same rounding.
    expected_amount = (BigDecimal("13.439945") * BigDecimal("183.94")).round(4)
    assert_equal expected_amount, holding.amount
  end

  test "sync twice keeps a single holding per position" do
    position = position_payload(isin: "US0378331005", quantity: "13.439945", price: "183.94")

    @tr_account.update!(raw_positions_payload: [ position ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account).process

    assert_no_difference "@account.holdings.count" do
      TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process
    end
  end

  test "position without valid price is skipped rather than guessed" do
    assert_no_difference "@account.holdings.count" do
      import_position(isin: "US0378331005", quantity: "13.439945", price: nil)
    end
  end

  test "empty portfolio creates no holdings and preserves prior financial state" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    holdings_before = @account.holdings.count

    # Successful but empty snapshot: nothing new to import, nothing destroyed.
    @tr_account.update!(raw_positions_payload: [])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_equal holdings_before, @account.holdings.count
  end

  test "explicit successful empty portfolio removes prior Trade Republic holdings" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    @tr_account.update!(holdings_snapshot_complete: true, raw_positions_payload: [])

    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
  end

  test "complete snapshot removes stale Trade Republic holdings" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    @tr_account.update!(holdings_snapshot_complete: true)

    @tr_account.update!(raw_positions_payload: [ position_payload(isin: "US0378331005", quantity: "1", price: "200") ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
    assert_not_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US0378331005_#{Date.current}")
  end

  test "complete snapshot preserves holdings from previous dates" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    historical_holding = @account.holdings.find_by!(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
    historical_holding.update!(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.yesterday}")

    @tr_account.update!(holdings_snapshot_complete: true, raw_positions_payload: [])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert @account.holdings.exists?(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.yesterday}")
  end

  test "incomplete snapshot preserves stale Trade Republic holdings" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    @tr_account.update!(holdings_snapshot_complete: false)

    @tr_account.update!(raw_positions_payload: [ position_payload(isin: "US0378331005", quantity: "1", price: "200") ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_not_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
  end

  test "zero and negative quantities are not imported" do
    assert_no_difference "@account.holdings.count" do
      @tr_account.update!(raw_positions_payload: [
        position_payload(isin: "US0378331005", quantity: "0", price: "200"),
        position_payload(isin: "US5933661043", quantity: "-1", price: "200")
      ])
      TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process
    end
  end

  private

    def import_position(isin:, quantity:, price:, average_cost: nil)
      @tr_account.update!(raw_positions_payload: [ position_payload(isin:, quantity:, price:, average_cost:) ])
      TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process
    end

    def position_payload(isin:, quantity:, price:, average_cost: nil)
      {
        "isin" => isin,
        "name" => "Test Security",
        "quantity" => quantity,
        "price" => price,
        "average_cost" => average_cost
      }.compact
    end
end
