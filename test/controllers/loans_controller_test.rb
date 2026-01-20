require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
  end

  test "creates with loan details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Loan",
          balance: 50000,
          currency: "USD",
          institution_name: "Local Bank",
          institution_domain: "localbank.example",
          notes: "Mortgage notes",
          accountable_type: "Loan",
          accountable_attributes: {
            interest_rate: 5.5,
            term_months: 60,
            rate_type: "fixed",
            initial_balance: 50000
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Loan", created_account.name
    assert_equal 50000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Local Bank", created_account[:institution_name]
    assert_equal "localbank.example", created_account[:institution_domain]
    assert_equal "Mortgage notes", created_account[:notes]
    assert_equal 5.5, created_account.accountable.interest_rate
    assert_equal 60, created_account.accountable.term_months
    assert_equal "fixed", created_account.accountable.rate_type
    assert_equal 50000, created_account.accountable.initial_balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with loan details" do
    assert_no_difference [ "Account.count", "Loan.count" ] do
      patch loan_path(@account), params: {
        account: {
          name: "Updated Loan",
          balance: 45000,
          currency: "USD",
          institution_name: "Updated Bank",
          institution_domain: "updatedbank.example",
          notes: "Updated loan notes",
          accountable_type: "Loan",
          accountable_attributes: {
            id: @account.accountable_id,
            interest_rate: 4.5,
            term_months: 48,
            rate_type: "fixed",
            initial_balance: 48000
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Loan", @account.name
    assert_equal 45000, @account.balance
    assert_equal "Updated Bank", @account[:institution_name]
    assert_equal "updatedbank.example", @account[:institution_domain]
    assert_equal "Updated loan notes", @account[:notes]
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "creates with installment details" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { Installment.count } => 1 do
      post loans_path, params: {
        account: {
          name: "New Installment",
          currency: "USD",
          accountable_type: "Loan",
          installment_attributes: {
            installment_cost: 200,
            total_term: 6,
            current_term: 2,
            payment_period: "monthly",
            first_payment_date: Date.current.to_s
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Installment", created_account.name
    assert_equal "USD", created_account.currency
    assert_equal "installment", created_account.subtype
    assert_equal 2, created_account.installment.current_term
    assert_equal "monthly", created_account.installment.payment_period
    assert_equal created_account.installment.calculate_current_balance, created_account.balance

    assert_redirected_to created_account
    assert_equal "Loan account created", flash[:notice]
  end

  test "updates with installment details" do
    installment_account = accounts(:loan)
    installment_account.create_installment!(
      installment_cost: 150,
      total_term: 8,
      current_term: 1,
      payment_period: "monthly",
      first_payment_date: 2.months.ago.to_date
    )

    assert_difference "RecurringTransaction.count", 1 do
      patch loan_path(installment_account), params: {
        account: {
          name: "Updated Installment",
          currency: "USD",
          installment_attributes: {
            installment_cost: 250,
            total_term: 10,
            current_term: 3,
            payment_period: "monthly",
            first_payment_date: Date.current.to_s,
            source_account_id: accounts(:depository).id
          }
        }
      }
    end

    installment_account.reload

    assert_equal "Updated Installment", installment_account.name
    assert_equal "installment", installment_account.subtype
    assert_equal 3, installment_account.installment.current_term
    assert_equal 250, installment_account.installment.installment_cost
    assert_equal installment_account.installment.calculate_current_balance, installment_account.balance
    assert RecurringTransaction.find_by(installment_id: installment_account.installment.id)

    assert_redirected_to installment_account
    assert_equal "Loan account updated", flash[:notice]
  end
end
