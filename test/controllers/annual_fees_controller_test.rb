require "test_helper"

class AnnualFeesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @account = accounts(:credit_card)
  end

  test "lists cards with their next fee" do
    @account.credit_card.update!(annual_fee: 120, annual_fee_month: 4, annual_fee_day: 12)
    # A second card with no fee date must sort after it, not break the page.
    families(:dylan_family).accounts.create!(name: "No Fee Card", balance: 0, currency: "USD", owner: users(:family_admin), accountable: CreditCard.new)

    get annual_fees_url

    assert_response :success
    assert_select "[data-testid='annual-fees-table']", text: /#{@account.name}/
  end

  test "finds fees in card transactions" do
    @account.credit_card.update!(annual_fee: nil, annual_fee_month: nil, annual_fee_day: nil)
    @account.entries.create!(name: "Annual Membership Fee", amount: 120, currency: "USD", date: 2.months.ago.to_date, entryable: Transaction.new)

    post detect_annual_fees_url

    assert_redirected_to annual_fees_url
    assert_equal 120, @account.credit_card.reload.annual_fee
  end

  test "the card overview shows the next fee" do
    @account.credit_card.update!(annual_fee: 120, annual_fee_month: 4, annual_fee_day: 12)

    get account_url(@account, tab: "overview")

    assert_select "[data-testid='annual-fee']", text: /\$120/
  end

  test "converts annual and upcoming totals to the family currency" do
    today = Date.current
    @account.credit_card.update!(annual_fee: 100, annual_fee_month: today.month, annual_fee_day: today.day)
    @account.family.accounts.create!(name: "Euro card", balance: 0, currency: "EUR", owner: users(:family_admin),
                                    accountable: CreditCard.new(annual_fee: 100, annual_fee_month: today.month, annual_fee_day: today.day))
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: today, rate: 1.2)

    get annual_fees_url

    assert_response :success
    assert_select ".privacy-sensitive", text: "$220.00", count: 2
  end

  test "does not show an unconverted total when an exchange rate is unavailable" do
    @account.update!(currency: "EUR")
    @account.credit_card.update!(annual_fee: 100)
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    get annual_fees_url

    assert_response :success
    assert_select ".privacy-sensitive", text: "—"
  end

  test "a card without an exchange rate leaves the other cards in the total" do
    @account.credit_card.update!(annual_fee: 100, annual_fee_month: 1, annual_fee_day: 1)
    @account.family.accounts.create!(name: "Euro card", balance: 0, currency: "EUR", owner: users(:family_admin),
                                    accountable: CreditCard.new(annual_fee: 50, annual_fee_month: 1, annual_fee_day: 1))
    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    get annual_fees_url

    assert_select "[data-testid='annual-fees-yearly']" do
      assert_select ".privacy-sensitive", text: "$100.00"
      assert_select "span", text: "1 card left out, no exchange rate"
    end
  end

  test "read-only shares get no edit link" do
    sign_in users(:family_member)
    @account.credit_card.update!(annual_fee: 95, annual_fee_month: 3, annual_fee_day: 1)

    get annual_fees_url

    assert_select "[data-testid='annual-fees-table']", text: /#{@account.name}/
    assert_select "a[href=?]", edit_credit_card_path(@account), count: 0
  end
end
