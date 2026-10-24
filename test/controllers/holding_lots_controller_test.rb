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

  test "a negative, blank or non-numeric total is rejected and the lot is unchanged" do
    [ "-1", "", "abc", "12abc" ].each do |total|
      patch holding_lot_path(@holding, @lot), params: { holding_lot: { total_cost_basis: total } }

      assert_redirected_to account_path(@account, tab: "holdings")
      assert_equal I18n.t("holding_lots.update.error"), flash[:alert]
      assert_nil @lot.reload.manual_total_cost, total.inspect
    end
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

    @lot.update_columns(qty: @lot.qty - 1)
    get holding_path(@holding)
    assert_select "form[action='#{holding_lot_path(@holding, @lot)}']", count: 0
  end

  private
    def materialize
      Holding::Materializer.new(@account.reload, strategy: :forward, security_ids: [ @security.id ]).materialize_holdings
    end
end
