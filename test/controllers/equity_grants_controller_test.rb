require "test_helper"

class EquityGrantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
    @account.investment.update!(subtype: "stock_plan")
  end

  test "adds a grant and a repeating vest schedule" do
    post account_equity_grants_url(@account), params: { equity_grant: { ticker: "ACME", grant_identifier: "RS1", grant_date: "2025-03-01", total_units: "240", grant_type: "rsu" } }
    grant = @account.equity_grants.find_by!(grant_identifier: "RS1")

    post equity_grant_equity_vests_url(grant), params: { equity_vest: { vest_date: "2026-03-15", units: "20", every_months: "3", count: "4" } }

    assert_equal [ Date.new(2026, 3, 15), Date.new(2026, 6, 15), Date.new(2026, 9, 15), Date.new(2026, 12, 15) ], grant.vests.reload.map(&:vest_date)
    assert_redirected_to account_url(@account, tab: "grants")
  end

  test "the grants tab lists upcoming vests" do
    grant = @account.equity_grants.create!(ticker: "ACME", grant_identifier: "RS1")
    grant.vests.create!(vest_date: Date.current + 30, units: 10)
    grant.vests.create!(vest_date: Date.current - 30, units: 12, net_proceeds: 1500)

    get account_url(@account, tab: "grants")

    assert_response :success
    assert_select "[data-testid='grants-tab']"
  end

  test "only stock plan accounts have a grants tab" do
    @account.investment.update!(subtype: "401k")

    get account_url(@account)

    assert_select "[data-testid='grants-tab']", count: 0
  end

  test "imports vests from a CSV" do
    file = uploaded_file(filename: "vests.csv", content_type: "text/csv", content: "grant_id,vest_date,units\nRS1,2026-03-15,60\n")

    post import_account_equity_grants_url(@account), params: { file: file, ticker: "ACME" }

    assert_equal 1, @account.equity_grants.count
  end

  test "deletes a grant with its vests" do
    grant = @account.equity_grants.create!(ticker: "ACME")
    grant.vests.create!(vest_date: Date.current, units: 1)

    assert_difference [ "EquityGrant.count", "EquityVest.count" ], -1 do
      delete equity_grant_url(grant)
    end
  end

  test "converts grant and upcoming vest values to the account currency" do
    @account.update!(currency: "USD")
    @account.investment.update!(subtype: "stock_plan")
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)
    [ [ "ACME", "USD", 10 ], [ "EXAMPLE", "EUR", 20 ] ].each do |ticker, currency, price|
      security = Security.create!(ticker: ticker, name: ticker)
      security.prices.create!(date: Date.current, price: price, currency: currency)
      grant = @account.equity_grants.create!(ticker: ticker, total_units: 10)
      grant.vests.create!(vest_date: 1.month.from_now.to_date, units: 10)
    end

    get account_url(@account, tab: "grants")

    assert_response :success
    assert_select ".privacy-sensitive", text: "$400.00", count: 2
  end
end
