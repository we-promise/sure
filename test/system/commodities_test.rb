require "application_system_test_case"

class CommoditiesTest < ApplicationSystemTestCase
  include CommoditiesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    Family.any_instance.stubs(:get_link_token).returns("test-link-token")
    Commodity::Price.stubs(:fetch_provider_prices).returns({})

    [ Date.current, 10.days.ago.to_date ].each do |date|
      create_commodity_price(code: "XAU", date: date, price: 2500)
      create_commodity_price(code: "XAG", date: date, price: 30)
    end
  end

  test "adds gold and silver through the add flow and shows totals and P&L" do
    add_item "Gold", name: "1 oz Maple Leaf", form: "Coin", weight: 1, unit: "oz t", location: "Home safe", price: 2400, premium: 80
    assert_text "Item added"
    assert_text "1 oz Maple Leaf"

    add_item "Silver", name: "100 g bar", form: "Bar", weight: 100, unit: "g", location: "Bank deposit box", price: 90, premium: 10, vat: 19
    assert_text "100 g bar"

    within "[data-testid=commodity-summary]" do
      # Gold 0.9999 ozt x 2500 + silver 99.9 g / 31.1034768 x 30 = 2596.11
      assert_text "$2,596.11"
      # Cost 2480 + 119 = 2599
      assert_text "$2,599.00"
      assert_text "-$2.89"
      # Metal gain 2596.11 - 2490; premiums and costs -(80 + 10 + 19)
      assert_text "$106.11"
      assert_text "-$109.00"
      assert_text "131.00 g"
    end

    within "[data-testid=commodity-per-location]" do
      assert_text "Home safe"
      assert_text "Bank deposit box"
    end

    click_link "Troy ounces"
    within("[data-testid=commodity-summary]") { assert_text "4.212 oz t" }
    within("[data-testid=commodity-per-metal]") { assert_text "0.9999 oz t" }
  end

  test "clears the prefilled price when the new currency has no price" do
    open_add_form "Gold"
    fill_in "commodity_item[weight_value]", with: 1
    select "oz t", from: "commodity_item[weight_unit]"
    fill_in "commodity_item[purchase_date]", with: 10.days.ago.to_date
    select "Total for all pieces", from: "commodity_item[metal_price_basis]"
    assert_field "commodity_item[metal_price_value]", with: "2499.75"

    select "Japanese Yen (JPY)", from: "commodity_item[purchase_currency]"
    assert_field "commodity_item[metal_price_value]", with: ""
  end

  private
    def open_add_form(metal)
      visit root_url
      within "[data-controller='DS--tabs']" do
        click_button "All"
        click_link "New account"
      end
      click_link "Commodities"
      click_link metal
    end

    def add_item(metal, name:, form:, weight:, unit:, location:, price:, premium:, vat: nil)
      open_add_form metal

      fill_in "commodity_item[name]", with: name
      select form, from: "commodity_item[form]"
      fill_in "commodity_item[weight_value]", with: weight
      select unit, from: "commodity_item[weight_unit]"
      fill_in "commodity_item[new_location_name]", with: location
      fill_in "commodity_item[purchase_date]", with: 10.days.ago.to_date
      select "Total for all pieces", from: "commodity_item[metal_price_basis]"
      fill_in "commodity_item[metal_price_value]", with: price
      fill_in "commodity_item[premium]", with: premium
      fill_in "commodity_item[vat]", with: vat if vat
      click_button "Add #{metal}"
    end
end
