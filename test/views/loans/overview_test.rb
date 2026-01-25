require "test_helper"

class LoansOverviewTest < ActionView::TestCase
  include ApplicationHelper

  test "renders loan overview with remaining principal" do
    account = accounts(:loan)

    html = render(partial: "loans/tabs/overview", locals: { account: account })

    assert_includes html, format_money(account.remaining_principal_money)
  end
end
