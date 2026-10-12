require "test_helper"

class Transactions::TransactionCategoryViewTest < ActionView::TestCase
  include CategoriesHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    Current.session = Session.create!(user: @user)
  end

  test "renders the category picker for an investment-contribution outflow leg" do
    outflow_tx = Transaction.create!(kind: "investment_contribution")
    Entry.create!(
      account: accounts(:depository), entryable: outflow_tx,
      name: "Contribution", amount: 500, currency: "USD", date: Date.today
    )

    inflow_tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(
      account: accounts(:investment), entryable: inflow_tx,
      name: "Contribution", amount: -500, currency: "USD", date: Date.today
    )

    Transfer.create!(inflow_transaction: inflow_tx, outflow_transaction: outflow_tx, status: "confirmed")

    html = render(partial: "transactions/transaction_category", locals: {
      transaction: outflow_tx, variant: "desktop", in_split_group: false
    })

    assert_includes html, "category_dropdown"
  end

  test "shows the outflow's category read-only on an investment-contribution inflow leg" do
    category = categories(:income)
    outflow_tx = Transaction.create!(kind: "investment_contribution", category: category)
    Entry.create!(
      account: accounts(:depository), entryable: outflow_tx,
      name: "Contribution", amount: 500, currency: "USD", date: Date.today
    )

    inflow_tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(
      account: accounts(:investment), entryable: inflow_tx,
      name: "Contribution", amount: -500, currency: "USD", date: Date.today
    )

    Transfer.create!(inflow_transaction: inflow_tx, outflow_transaction: outflow_tx, status: "confirmed")

    html = render(partial: "transactions/transaction_category", locals: {
      transaction: inflow_tx.reload, variant: "desktop", in_split_group: false
    })

    assert_not_includes html, "category_dropdown"
    assert_includes html, category.display_name
    assert_includes html, I18n.t("transactions.transaction_category.set_on_outflow")
  end

  test "hides the outflow's category when the viewer cannot access the outflow's account" do
    category = categories(:income)
    owner_only = accounts(:investment).family.accounts.create!(
      owner: users(:family_admin), name: "Private checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    outflow_tx = Transaction.create!(kind: "investment_contribution", category: category)
    Entry.create!(account: owner_only, entryable: outflow_tx, name: "Contribution", amount: 500, currency: "USD", date: Date.today)
    inflow_tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(account: accounts(:investment), entryable: inflow_tx, name: "Contribution", amount: -500, currency: "USD", date: Date.today)
    Transfer.create!(inflow_transaction: inflow_tx, outflow_transaction: outflow_tx, status: "confirmed")

    @accessible_account_ids = [ accounts(:investment).id ]
    html = render(partial: "transactions/transaction_category", locals: {
      transaction: inflow_tx.reload, variant: "desktop", in_split_group: false
    })

    assert_not_includes html, category.display_name
    assert_includes html, transfer_category.display_name
  end

  test "renders the transfer badge instead of a picker for a regular funds-movement transfer" do
    outflow_tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(
      account: accounts(:depository), entryable: outflow_tx,
      name: "Transfer", amount: 500, currency: "USD", date: Date.today
    )

    inflow_tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(
      account: accounts(:connected), entryable: inflow_tx,
      name: "Transfer", amount: -500, currency: "USD", date: Date.today
    )

    Transfer.create!(inflow_transaction: inflow_tx, outflow_transaction: outflow_tx, status: "confirmed")

    html = render(partial: "transactions/transaction_category", locals: {
      transaction: outflow_tx, variant: "desktop", in_split_group: false
    })

    assert_includes html, transfer_category.display_name
    assert_not_includes html, "category_dropdown"
  end

  test "renders the category picker for an unmatched funds-movement leg with no Transfer record" do
    tx = Transaction.create!(kind: "funds_movement")
    Entry.create!(
      account: accounts(:depository), entryable: tx,
      name: "Unmatched internal movement", amount: 500, currency: "USD", date: Date.today
    )

    html = render(partial: "transactions/transaction_category", locals: {
      transaction: tx, variant: "desktop", in_split_group: false
    })

    assert_includes html, "category_dropdown"
  end
end
