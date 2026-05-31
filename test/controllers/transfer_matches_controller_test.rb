require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "new transfer entry is protected from provider sync" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    new_entry = transfer.inflow_transaction.entry

    assert new_entry.user_modified?, "New transfer entry should be marked as user_modified to protect from provider sync"
  end

  test "assigns investment_contribution kind and category for investment destination" do
    # Outflow from depository (positive amount), target is investment
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    outflow_entry.reload
    outflow_txn = outflow_entry.entryable

    assert_equal "investment_contribution", outflow_txn.kind

    category = @user.family.investment_contributions_category
    assert_equal category, outflow_txn.category
  end

  test "shows annuity split preview before matching existing cash payment to new loan transaction" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    assert_no_difference [ "Transfer.count", "Entry.count", "Transaction.count" ] do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "new",
          target_account_id: loan_account.id
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid='loan-payment-split-preview']"
    assert_select "button[name='transfer_match[loan_payment_split_action]'][value='accept']"
    assert_select "button[name='transfer_match[loan_payment_split_action]'][value='unmatched']"
  end

  test "accepts annuity split when matching existing cash payment to new loan transaction" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    assert_difference -> { Transfer.count } => 1,
      -> { Entry.count } => 3,
      -> { Transaction.count } => 3 do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "new",
          target_account_id: loan_account.id,
          loan_payment_split_action: "accept"
        }
      }
    end

    payment_entry.reload
    transfer = Transfer.order(created_at: :desc).first

    assert payment_entry.split_parent?
    assert_equal "loan_payment", transfer.outflow_transaction.kind
    assert_equal "funds_movement", transfer.inflow_transaction.kind
    assert_in_delta 298.65, transfer.outflow_transaction.entry.amount, 0.01
    assert_in_delta(-298.65, transfer.inflow_transaction.entry.amount, 0.01)

    interest_entry = payment_entry.child_entries.where(name: "Interest for #{loan_account.name}").sole
    assert_in_delta 1500, interest_entry.amount, 0.01
    assert_equal "standard", interest_entry.transaction.kind
  end

  private
    def create_annuity_loan_account
      loan = Loan.new(
        annuity_enabled: true,
        started_on: Date.new(2024, 1, 1),
        payment_cadence: "monthly",
        initial_balance: 300000,
        term_months: 360,
        rate_type: "fixed"
      )
      loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)

      @user.family.accounts.create!(
        name: "Annuity Mortgage",
        balance: 300000,
        currency: "USD",
        accountable: loan
      )
    end
end
