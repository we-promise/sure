require "test_helper"

class Loans::OverviewTest < ActionView::TestCase
  test "uses installment remaining for summary card" do
    loan = Loan.create!(interest_rate: 3.5, term_months: 12, rate_type: "fixed")
    account = Account.create!(
      family: families(:dylan_family),
      name: "Installment Loan",
      balance: 0,
      currency: "USD",
      accountable: loan,
      status: "active"
    )
    Installment.create!(
      account: account,
      installment_cost: 30,
      total_term: 3,
      current_term: 0,
      payment_period: "monthly",
      first_payment_date: Date.tomorrow
    )

    html = render(partial: "loans/tabs/overview", locals: { account: account })

    assert_includes html, format_money(account.remaining_principal_money)
    assert_not_includes html, format_money(account.balance_money)
  end

  test "uses account balance for non-installment loans" do
    account = accounts(:loan)

    html = render(partial: "loans/tabs/overview", locals: { account: account })

    assert_includes html, format_money(account.balance_money)
  end
end
