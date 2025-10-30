require "test_helper"

class Transactions::MergedBadgeViewTest < ActionView::TestCase

  # Render the transactions/_transaction partial and ensure the merged badge appears
  test "renders merged badge when transaction.was_merged is true" do
    family = families(:one) rescue Family.first || Family.create!(name: "Test Family")
    account = accounts(:checking) rescue family.accounts.first || Account.create!(
      family: family,
      name: "Checking",
      currency: "USD",
      accountable: CheckingAccount.new
    )

    transaction = Transaction.create!(was_merged: true)
    entry = Entry.create!(
      account: account,
      entryable: transaction,
      name: "Cafe",
      amount: -987,
      currency: "USD",
      date: Date.today
    )

    html = render(partial: "transactions/transaction", locals: { entry: entry, balance_trend: nil, view_ctx: "global" })

    assert_includes html, "Merged from pending to posted", "Expected merged tooltip text to be present"
  end
end
