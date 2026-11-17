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
end
