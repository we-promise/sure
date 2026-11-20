require "test_helper"

class HoldingPriceChartsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @holding = holdings(:one)
  end

  test "renders the security's closes over the period in the holding's frame" do
    get holding_price_chart_path(@holding), params: { period: "last_7_days" }

    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(@holding, :price_chart)}" do
      assert_select "[data-controller='time-series-chart']"
      assert_select "select[name='period'] option[selected][value='last_7_days']"
    end
  end

  test "says so when the period holds fewer than two closes" do
    security = Security.create!(ticker: "NOPX", name: "No prices")
    holding = @holding.account.holdings.create!(security: security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    get holding_price_chart_path(holding)

    assert_response :success
    assert_select "[data-controller='time-series-chart']", count: 0
    assert_select "p", text: I18n.t("holding_price_charts.show.no_data")
  end

  test "does not show another family's holding" do
    sign_in users(:empty)

    get holding_price_chart_path(@holding)

    assert_response :not_found
  end
end
