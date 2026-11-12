require "test_helper"

class HoldingLotsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
    @security = Security.create!(ticker: "LOTC", name: "LOTC")
    Security::Price.insert_all((2.days.ago.to_date..Date.current).map { |date| { security_id: @security.id, date: date, price: 30, currency: "USD" } })
    create_trade(@security, account: @account, qty: 60, price: 12, date: 2.days.ago.to_date)
    @buy = create_trade(@security, account: @account, qty: 40, price: 20, date: 1.day.ago.to_date)
    materialize
    @holding = @account.holdings.find_by!(security: @security, date: Date.current)
    @lot = HoldingLot.find_by!(source_entry: @buy)
  end

  test "update sets one lot's cost, locks it and restates the position" do
    assert_equal BigDecimal("15.2"), @holding.cost_basis

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }

    assert_redirected_to account_path(@account, tab: "holdings")
    assert_equal 600, @lot.reload.manual_total_cost
    assert_equal BigDecimal("13.2"), @holding.reload.cost_basis, "(720 + 600) / 100, without waiting for a sync"
  end

  # A restatement and a sync of the same account both lock the account row
  # before writing any holdings, so they serialise in one lock order. The lot
  # change is made under that lock too.
  # A remap can commit while the request waits for the account lock; the
  # request then acts on where the holding and its lot are now.
  test "an edit made while a remap moves the lot restates the security it moved to" do
    moved_to = securities(:msft)
    Account.any_instance.stubs(:lock!).with do |*|
      Holding.where(id: @holding.id).update_all(security_id: moved_to.id)
      HoldingLot.where(id: @lot.id).update_all(security_id: moved_to.id)
      true
    end.returns(true)
    materializer = stub(materialize_balances: true)
    Balance::Materializer.expects(:new).with(anything, has_entry(security_ids: [ moved_to.id ])).returns(materializer)

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }

    assert_equal 600, @lot.reload.manual_total_cost
  end

  # The provider-cost refusal is checked again under the lock, since a sync
  # or remap may have handed the position a provider's cost while it waited.
  test "an edit is refused if the provider's cost arrives while it waits for the lock" do
    Account.any_instance.stubs(:lock!).with do |*|
      Holding.where(id: @holding.id).update_all(cost_basis: 18, cost_basis_source: "provider")
      true
    end.returns(true)

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }

    assert_nil @lot.reload.manual_total_cost
  end

  test "an edit changes the lot and restates under the account's row lock, taken first" do
    expect_locked_restate(:update)

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }

    assert_redirected_to account_path(@account, tab: "holdings")
  end

  test "an unlock changes the lot and restates under the account's row lock, taken first" do
    expect_locked_restate(:unlock_cost!)

    post unlock_holding_lot_path(@holding, @lot)

    assert_redirected_to account_path(@account, tab: "holdings")
  end

  # The new cost and the holdings restated from it are one change: a
  # restatement that fails leaves the lot as it was.
  test "an edit whose restatement fails leaves the lot's cost unchanged" do
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(RuntimeError, "restatement failed")

    assert_raises(RuntimeError) do
      patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }
    end

    assert_nil @lot.reload.manual_total_cost
  end

  test "an unlock whose restatement fails leaves the lot's cost unchanged" do
    @lot.set_manual_total_cost!(600)
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(RuntimeError, "restatement failed")

    assert_raises(RuntimeError) do
      post unlock_holding_lot_path(@holding, @lot)
    end

    assert_equal 600, @lot.reload.manual_total_cost
  end

  # Restatement leaves a provider's rows alone, so a lot cost set under a
  # provider's figure would change nothing the position shows. A cost set
  # before the provider supplied one can still be cleared, since a fifo
  # account's disposals still read it.
  test "a lot cost cannot be set while the provider supplies the position's cost, only cleared" do
    @lot.set_manual_total_cost!(500)
    @holding.update_columns(cost_basis: 18, cost_basis_source: "provider")

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }
    assert_redirected_to account_path(@account, tab: "holdings")
    assert_equal I18n.t("holding_lots.provider_cost"), flash[:alert]
    assert_equal 500, @lot.reload.manual_total_cost

    post unlock_holding_lot_path(@holding, @lot)
    assert_redirected_to account_path(@account, tab: "holdings")
    assert_equal I18n.t("holding_lots.unlock.success"), flash[:notice]
    assert_nil @lot.reload.manual_total_cost
  end

  # The position's latest row decides, whichever row the request names.
  test "an earlier row of a provider-cost position does not open the editor" do
    @holding.update_columns(cost_basis: 18, cost_basis_source: "provider")
    earlier = @account.holdings.find_by!(security: @security, date: 1.day.ago.to_date)

    patch holding_lot_path(earlier, @lot), params: { holding_lot: { total_cost_basis: "600" } }

    assert_equal I18n.t("holding_lots.provider_cost"), flash[:alert]
    assert_nil @lot.reload.manual_total_cost
  end

  test "the drawer offers the lot editor for a calculated cost, not a provider's" do
    get holding_path(@holding)
    assert_select "li[data-lot-id='#{@lot.id}'] details", 1
    assert_select "form[action='#{holding_lot_path(@holding, @lot)}']", 1
    assert_select "p", text: /#{Regexp.escape(I18n.t("holdings.lots.provider_cost_hint"))}/, count: 0

    @holding.update_columns(cost_basis: 18, cost_basis_source: "provider")
    get holding_path(@holding)
    assert_select "li[data-lot-id='#{@lot.id}']", 1
    assert_select "li[data-lot-id] details", 0
    assert_select "form[action='#{holding_lot_path(@holding, @lot)}']", 0
    assert_select "form[action='#{unlock_holding_lot_path(@holding, @lot)}']", 0, "no manual cost to clear"
    assert_select "p", text: /#{Regexp.escape(I18n.t("holdings.lots.provider_cost_hint"))}/, count: 1
    assert_select "p", text: /#{Regexp.escape(I18n.t("holdings.lots.provider_cost_clear_hint"))}/, count: 0
  end

  # Under a provider's cost, a lot's manual cost can only be cleared.
  test "the drawer offers only the clear control for a manual cost under a provider's" do
    @lot.set_manual_total_cost!(500)
    @holding.update_columns(cost_basis: 18, cost_basis_source: "provider")

    get holding_path(@holding)

    assert_select "form[action='#{holding_lot_path(@holding, @lot)}'][method='post'] input[name='holding_lot[total_cost_basis]']", 0
    assert_select "li[data-lot-id='#{@lot.id}'] form[action='#{unlock_holding_lot_path(@holding, @lot)}']", 1
    assert_select "p", text: /#{Regexp.escape(I18n.t("holdings.lots.provider_cost_clear_hint"))}/, count: 1
  end

  test "a read-only share is not offered the clear control under a provider's cost" do
    @lot.set_manual_total_cost!(500)
    @holding.update_columns(cost_basis: 18, cost_basis_source: "provider")
    Account.stubs(:writable_by).returns(Account.none)

    get holding_path(@holding)

    assert_select "form[action='#{unlock_holding_lot_path(@holding, @lot)}']", 0
    assert_select "p", text: /#{Regexp.escape(I18n.t("holdings.lots.provider_cost_clear_hint"))}/, count: 0
  end

  test "resubmitting the same lot id updates it in place and never duplicates" do
    id, created_at = @lot.id, @lot.created_at

    assert_no_difference "HoldingLot.count" do
      patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "720" } }
      patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }
    end

    lot = HoldingLot.find_by!(source_entry: @buy)
    assert_equal [ id, created_at, 600 ], [ lot.id, lot.created_at, lot.manual_total_cost ]
  end

  test "unlock returns the lot to its trade's cost" do
    @lot.set_manual_total_cost!(600)
    materialize

    post unlock_holding_lot_path(@holding, @lot)

    assert_redirected_to account_path(@account, tab: "holdings")
    assert_equal "Manual cost cleared.", flash[:notice], "a lot with no trade price returns to unknown, not a price"
    assert_nil @lot.reload.manual_total_cost
    assert_equal BigDecimal("15.2"), @holding.reload.cost_basis
  end

  test "another family's lot id is 404" do
    other = families(:empty).accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Investment.new)
    other_lot = HoldingLot.create!(account: other, security: @security, source_entry: create_trade(@security, account: other, qty: 1, price: 10, date: Date.current), qty: 1, currency: "USD")

    patch holding_lot_path(@holding, other_lot), params: { holding_lot: { total_cost_basis: "5" } }

    assert_response :not_found
    assert_nil other_lot.reload.manual_total_cost
  end

  test "an opening lot is not editable" do
    opening = HoldingLot.create!(account: @account, security: @security, origin_security: @security, qty: 0, currency: "USD")

    patch holding_lot_path(@holding, opening), params: { holding_lot: { total_cost_basis: "5" } }

    assert_response :not_found
    assert_nil opening.reload.manual_total_cost
  end

  test "a negative, blank, non-numeric, non-finite or oversized total is rejected and the lot is unchanged" do
    [ "-1", "", "abc", "12abc", "Infinity", "NaN", "10000000000000000" ].each do |total|
      patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: total } }

      assert_redirected_to account_path(@account, tab: "holdings")
      assert_equal I18n.t("holding_lots.update.error"), flash[:alert]
      assert_nil @lot.reload.manual_total_cost, total.inspect
    end
  end

  # The cost per unit is stored with 15 digits before the point, as a
  # holding's cost basis is; on half a unit that bound comes before the
  # total's own.
  test "a total is accepted only while its cost per unit fits below 10^15" do
    entry = create_trade(@security, account: @account, qty: BigDecimal("0.5"), price: 1, date: Date.current)
    materialize
    half = HoldingLot.find_by!(source_entry: entry)

    patch holding_lot_path(@holding, half), params: { holding_lot: { total_cost_basis: "500000000000000" } }
    assert_equal I18n.t("holding_lots.update.error"), flash[:alert], "10^15 a unit"
    assert_nil half.reload.manual_total_cost

    patch holding_lot_path(@holding, half), params: { holding_lot: { total_cost_basis: "499999999999999.9999" } }
    assert_equal I18n.t("holding_lots.update.success"), flash[:notice]
    assert_equal BigDecimal("499999999999999.9999"), half.reload.manual_total_cost
  end

  test "a total is accepted only while it fits its column, however many units it spreads over" do
    entry = create_trade(@security, account: @account, qty: 2_000_000, price: 1, date: Date.current)
    materialize
    big = HoldingLot.find_by!(source_entry: entry)

    patch holding_lot_path(@holding, big), params: { holding_lot: { total_cost_basis: "1000000000000000" } }
    assert_equal I18n.t("holding_lots.update.error"), flash[:alert]
    assert_nil big.reload.manual_total_cost

    patch holding_lot_path(@holding, big), params: { holding_lot: { total_cost_basis: "999999999999999.9999" } }
    assert_equal I18n.t("holding_lots.update.success"), flash[:notice]
    assert_equal BigDecimal("999999999999999.9999"), big.reload.manual_total_cost
  end

  test "qty and acquired_on are not permitted on a derived lot" do
    before = [ @lot.qty, @lot.acquired_on ]

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600", qty: "1", acquired_on: "2000-01-01" } }

    assert_equal before, [ @lot.reload.qty, @lot.acquired_on ]
    assert_equal 600, @lot.manual_total_cost
  end

  test "a read-only member cannot edit a lot" do
    @account.account_shares.create!(user: users(:family_member), permission: "read_only", include_in_finances: true)
    sign_in users(:family_member)

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_nil @lot.reload.manual_total_cost
  end

  test "the drawer lists the position's lots, and only while they add up to it" do
    get holding_path(@holding)
    assert_select "form[action='#{holding_lot_path(@holding, @lot)}']", count: 1
    # The row shows a cost per unit while its editor takes the lot's total.
    assert_select "summary", text: /\$20\.00 per unit/

    @lot.update_columns(qty: @lot.qty - 1)
    get holding_path(@holding)
    assert_select "form[action='#{holding_lot_path(@holding, @lot)}']", count: 0
  end

  # The lots are today's: an earlier row of the same position, even one that
  # held the same quantity, does not offer them.
  test "an earlier holding of the position lists no lots" do
    earlier = @account.holdings.find_by!(security: @security, date: 1.day.ago.to_date)
    assert_equal @holding.qty, earlier.qty, "the quantity alone cannot tell them apart"

    get holding_path(earlier)
    assert_select "form[action^='#{holding_path(earlier)}/lots']", count: 0
    get holding_path(@holding)
    assert_select "form[action='#{holding_lot_path(@holding, @lot)}']", count: 1
  end

  # The editor shows a saved total to the places it was stored at, so saving
  # the form unchanged keeps it.
  test "the cost editor reopens a sub-cent total as it was saved" do
    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600.0001" } }
    get holding_path(@holding)
    assert_select "input[name='holding_lot[total_cost_basis]'][value='600.0001']", count: 1

    patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: "600" } }
    get holding_path(@holding)
    assert_select "input[name='holding_lot[total_cost_basis]'][value='600.00']", count: 1
  end

  test "a lot row discloses a form only where it can be edited" do
    opening = HoldingLot.create!(account: @account, security: @security, origin_security: @security, qty: 5, currency: "USD")
    @holding.update_columns(qty: @holding.qty + 5)

    get holding_path(@holding)

    assert_select "li[data-lot-id='#{@lot.id}'] details", 1
    assert_select "li[data-lot-id='#{opening.id}'] details", 0
    assert_select "li[data-lot-id='#{opening.id}']", text: /#{I18n.t("holdings.lots.opening")}/
  end

  test "a read-only share shows every lot without a disclosure" do
    Account.stubs(:writable_by).returns(Account.none)

    get holding_path(@holding)

    assert_select "li[data-lot-id='#{@lot.id}']", 1
    assert_select "li[data-lot-id] details", 0
  end

  private
    # Mocha verifies these at teardown, so a request that skips the lock, the
    # change or the restatement fails.
    def expect_locked_restate(change)
      order = sequence("restate")
      Account.any_instance.expects(:lock!).at_least_once.in_sequence(order).returns(true)
      HoldingLot.any_instance.expects(change).in_sequence(order).returns(true)
      Holding::Materializer.any_instance.expects(:materialize_holdings).in_sequence(order).returns([])
    end

    def materialize
      Holding::Materializer.new(@account.reload, strategy: :forward, security_ids: [ @security.id ]).materialize_holdings
    end
end
