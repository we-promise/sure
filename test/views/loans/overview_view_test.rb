require "test_helper"

# The Overview tab captures one reference date and every date-sensitive figure
# on it -- the repayment card's current instalment and cumulative totals
# included -- answers for it.
class LoanOverviewViewTest < ActionView::TestCase
  include LedgerTestingHelper

  helper AccountsHelper, LoansHelper
  helper do
    def preview_features_enabled?
      Current.user&.preview_features_enabled? == true
    end
  end

  setup do
    @user = users(:family_admin)
    enable_preview_features_for_family!(@user.family)
    @user.reload
    Current.session = @user.sessions.create!

    @account = Account.create!(
      family: families(:dylan_family),
      name: "Overview Loan",
      balance: 12_000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "auto", interest_rate: 0, term_months: 12,
        rate_type: "fixed", start_date: Date.new(2026, 1, 15),
        initial_balance: 12_000
      )
    )
  end

  teardown { Current.session = nil }

  test "the current instalment is the one for the page's date, not the clock's" do
    travel_to Date.new(2026, 9, 28) do
      render partial: "loans/tabs/overview", locals: { account: @account, as_of: Date.new(2026, 4, 20) }
    end

    assert_includes rendered, "Payment 4 ·", "the instalment on the page's date"
    assert_not_includes rendered, "Payment 9 ·", "not the one the clock is on"
  end

  test "the overview shows the principal and interest paid through its reference date" do
    @account.entries.create!(
      date: Date.new(2026, 1, 15), name: "Opening balance", amount: 12_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @account.entries.create!(
      date: Date.new(2026, 2, 15), name: "Loan payment", amount: -1_000, currency: "USD",
      entryable: Transaction.new
    )
    @account.update_column(:balance, 11_000)

    render partial: "loans/tabs/overview", locals: { account: @account, as_of: Date.new(2026, 4, 20) }

    assert_select "section", text: /Paid so far/ do |cards|
      assert_equal 1, cards.size
      assert_includes cards.first.text, "April 20, 2026"
      assert_includes cards.first.text, "Principal + interest"
      assert_includes cards.first.text, "$1,000.00", "the principal paid so far"
      assert_includes cards.first.text, "$0.00", "no interest on an interest-free loan"
    end
    assert_includes rendered, "md:grid-cols-3", "three cards share the full width"
  end

  test "the overview hides the paid card when nothing has been paid" do
    @account.entries.create!(
      date: Date.new(2026, 1, 15), name: "Opening balance", amount: 12_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    render partial: "loans/tabs/overview", locals: { account: @account, as_of: Date.new(2026, 1, 15) }

    assert_no_match(/Paid so far/, rendered)
    assert_includes rendered, "md:grid-cols-2", "two cards do not leave a gap"
    assert_not_includes rendered, "md:grid-cols-3"
  end
end
