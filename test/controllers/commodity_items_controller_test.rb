require "test_helper"

class CommodityItemsControllerTest < ActionDispatch::IntegrationTest
  include CommoditiesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "metal picker lists configured commodities" do
    get new_commodity_path
    assert_response :success
    Commodity.metals.each { |metal| assert_select "a[href=?]", new_commodity_item_path(code: metal.code), text: /#{metal.name}/ }
  end

  test "first item creates a Commodities account automatically" do
    assert_difference -> { Account.where(accountable_type: "Commodity").count } => 1, -> { Commodity::Item.count } => 1,
                      -> { Security.count } => 0, -> { Entry.count } => 0 do
      post commodity_items_path, params: { commodity_item: item_params.merge(new_location_name: "Home safe") }
    end

    item = Commodity::Item.order(:created_at).last
    assert_redirected_to account_path(item.account, tab: "inventory")
    assert_equal [ "Commodities", @family.currency, "Commodity" ], [ item.account.name, item.account.currency, item.account.accountable_type ]
    assert_equal "Home safe", item.location.name
    assert_equal BigDecimal("31.1034768"), item.gross_weight_grams
  end

  test "adds to the chosen account when several exist" do
    create_commodity_account(name: "Home")
    vault = create_commodity_account(name: "Vault Zurich")

    assert_no_difference -> { Account.count } do
      post commodity_items_path, params: { commodity_item: item_params.merge(account_id: vault.id) }
    end

    assert_equal vault, Commodity::Item.order(:created_at).last.account
  end

  test "invalid item re-renders the form without creating an account" do
    assert_no_difference -> { Account.count } do
      post commodity_items_path, params: { commodity_item: item_params.merge(fineness: 2) }
    end

    assert_response :unprocessable_entity
  end

  test "moves an item and records history" do
    account = create_commodity_account
    item = create_commodity_item(account: account)

    patch move_commodity_item_path(item), params: { commodity_item: { new_location_name: "Bank deposit box", moved_on: Date.current } }

    assert_equal "Bank deposit box", item.reload.location.name
    assert_equal 1, item.moves.count
  end

  test "records a partial sale" do
    account = create_commodity_account
    item = create_commodity_item(account: account, quantity: 5)

    post commodity_item_sales_path(item), params: { commodity_sale: { date: Date.current, quantity: 2, proceeds: 2100, proceeds_basis: "per_piece", costs: 10, currency: "USD" } }

    assert_redirected_to account_path(account, tab: "inventory")
    assert_equal 3, item.reload.remaining_quantity
    assert_equal BigDecimal("4200"), item.sales.sole.proceeds
  end

  test "inventory tab renders totals and toggles weight units" do
    account = create_commodity_account
    create_commodity_item(account: account)
    create_commodity_price(code: "XAU", date: Date.current, price: 2500)

    get account_path(account, tab: "inventory")
    assert_response :success
    assert_select "[data-testid=commodity-summary]", text: /31\.10 g/

    patch commodity_weight_unit_path(unit: "ozt")
    assert_equal "ozt", @user.reload.commodity_weight_unit

    get account_path(account, tab: "inventory")
    assert_select "[data-testid=commodity-summary]", text: /0\.9999 oz t/
  end

  test "price lookup returns the stored price converted per ounce and gram" do
    create_commodity_price(code: "XAU", date: Date.current, price: BigDecimal("3110.34768"))

    get commodity_price_lookup_path(code: "XAU", date: Date.current, currency: "USD")

    body = JSON.parse(response.body)
    assert_equal [ "3110.3477", "100.0", "metal_price_api" ], body.values_at("price_per_ozt", "price_per_g", "source").map(&:to_s)
  end

  private
    def item_params
      {
        code: "XAU", name: "1 oz Maple Leaf", form: "coin", quantity: 1, weight_value: 1, weight_unit: "ozt",
        fineness: "0.9999", purchase_date: Date.current - 5, purchase_currency: "USD",
        metal_price_value: 2400, metal_price_basis: "total", premium: 80, premium_basis: "total"
      }
    end
end
