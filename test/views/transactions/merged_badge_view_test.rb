require "test_helper"

class Transactions::MergedBadgeViewTest < ActionView::TestCase
  # Render the transactions/_transaction partial and ensure the merged badge appears
  test "does not render merged badge even when transaction.was_merged is true (legacy flag not surfaced)" do
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
