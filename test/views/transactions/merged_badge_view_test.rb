require "test_helper"

class Transactions::MergedBadgeViewTest < ActionView::TestCase
  # Render the transactions/_transaction partial and verify the merged badge does not appear
  test "does not render merged badge after was_merged column removal" do
    account = accounts(:depository)

    transaction = Transaction.create!
    entry = Entry.create!(
      account: account,
      entryable: transaction,
      name: "Cafe",
      amount: -987,
      currency: "USD",
      date: Date.today
    )

    html = render(partial: "transactions/transaction", locals: { entry: entry, balance_trend: nil, view_ctx: "global" })

    assert_not_includes html, "Merged from pending to posted", "Merged badge should no longer be shown in UI"
  end
end
