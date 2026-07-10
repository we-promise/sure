require "test_helper"

class Transactions::TransferCounterpartViewTest < ActionView::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    Current.session = Session.create!(user: @user)

    @checking = accounts(:depository) # "from" account
    @savings = accounts(:credit_card) # "to" account

    @accessible_account_ids = @user.accessible_accounts.pluck(:id).to_set
  end

  test "renders outflow transfer with arrow to destination account" do
    outflow_tx = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(
      account: @checking, entryable: outflow_tx,
      name: "Transfer to Savings", amount: 100, currency: "USD", date: Date.today
    )

    inflow_tx = Transaction.create!(kind: "funds_movement")
    inflow_entry = Entry.create!(
      account: @savings, entryable: inflow_tx,
      name: "Transfer from Checking", amount: -100, currency: "USD", date: Date.today
    )

    Transfer.create!(
      inflow_transaction: inflow_tx,
      outflow_transaction: outflow_tx,
      status: "confirmed"
    )

    html = render(partial: "transactions/transaction", locals: {
      entry: outflow_entry, balance_trend: nil, view_ctx: "global"
    })

    assert_includes html, "→"
    assert_includes html, @savings.name
  end

  test "renders inflow transfer with arrow from source account" do
    outflow_tx = Transaction.create!(kind: "funds_movement")
    outflow_entry = Entry.create!(
      account: @checking, entryable: outflow_tx,
      name: "Transfer to Savings", amount: 100, currency: "USD", date: Date.today
    )

    inflow_tx = Transaction.create!(kind: "funds_movement")
    inflow_entry = Entry.create!(
      account: @savings, entryable: inflow_tx,
      name: "Transfer from Checking", amount: -100, currency: "USD", date: Date.today
    )

    Transfer.create!(
      inflow_transaction: inflow_tx,
      outflow_transaction: outflow_tx,
      status: "confirmed"
    )

    html = render(partial: "transactions/transaction", locals: {
      entry: inflow_entry, balance_trend: nil, view_ctx: "global"
    })

    assert_includes html, "←"
    assert_includes html, @checking.name
  end

  test "falls back to account name when transfer has no counterpart" do
    tx = Transaction.create!(kind: "funds_movement")
    entry = Entry.create!(
      account: @checking, entryable: tx,
      name: "Unmatched Transfer", amount: 100, currency: "USD", date: Date.today
    )

    html = render(partial: "transactions/transaction", locals: {
      entry: entry, balance_trend: nil, view_ctx: "global"
    })

    assert_includes html, @checking.name
    assert_not_includes html, "→"
    assert_not_includes html, "←"
  end
end
