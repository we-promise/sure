require "test_helper"

class LoansControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    ensure_tailwind_build
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
            subtype: "mortgage",
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
    assert_equal "mortgage", created_account.accountable.subtype
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
            subtype: "auto",
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
    assert_equal "auto", @account.accountable.subtype
    assert_equal 4.5, @account.accountable.interest_rate
    assert_equal 48, @account.accountable.term_months
    assert_equal "fixed", @account.accountable.rate_type
    assert_equal 48000, @account.accountable.initial_balance

    assert_redirected_to @account
    assert_equal "Loan account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "creates annuity loan with rate periods" do
    assert_difference -> { Account.count } => 1,
      -> { Loan.count } => 1,
      -> { LoanRatePeriod.count } => 2 do
      post loans_path, params: {
        account: {
          name: "New Annuity Mortgage",
          balance: 300000,
          currency: "USD",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            annuity_enabled: "1",
            started_on: "2024-01-01",
            payment_cadence: "monthly",
            term_months: 360,
            initial_balance: 300000,
            loan_rate_periods_attributes: {
              "0" => { starts_on: "2024-01-01", annual_rate: "6.0" },
              "1" => { starts_on: "2029-01-01", annual_rate: "5.0", payment_amount: "1750" }
            }
          }
        }
      }
    end

    loan = Account.order(:created_at).last.loan

    assert loan.annuity_enabled?
    assert_equal Date.new(2024, 1, 1), loan.started_on
    assert_equal "monthly", loan.payment_cadence
    assert_equal [ Date.new(2024, 1, 1), Date.new(2029, 1, 1) ], loan.loan_rate_periods.order(:starts_on).pluck(:starts_on)
    assert_equal 1750, loan.loan_rate_periods.order(:starts_on).last.payment_amount
  end

  test "updates annuity loan rate periods" do
    period = @account.loan.loan_rate_periods.create!(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account.loan.update!(
      annuity_enabled: true,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      initial_balance: 500000,
      term_months: 360
    )

    assert_no_difference [ "Account.count", "Loan.count" ] do
      assert_difference -> { LoanRatePeriod.count } => 1 do
        patch loan_path(@account), params: {
          account: {
            name: @account.name,
            balance: @account.balance,
            currency: @account.currency,
            accountable_type: "Loan",
            accountable_attributes: {
              id: @account.accountable_id,
              subtype: "mortgage",
              annuity_enabled: "1",
              started_on: "2024-01-01",
              payment_cadence: "monthly",
              term_months: 360,
              initial_balance: 500000,
              loan_rate_periods_attributes: {
                "0" => { id: period.id, starts_on: "2024-01-01", annual_rate: "5.5" },
                "1" => { starts_on: "2029-01-01", annual_rate: "4.75" }
              }
            }
          }
        }
      end
    end

    @account.loan.reload

    assert_equal [ 5.5, 4.75 ], @account.loan.loan_rate_periods.order(:starts_on).map { |rate_period| rate_period.annual_rate.to_f }
  end

  test "rejects invalid annuity rate periods" do
    assert_no_difference [ "Account.count", "Loan.count", "LoanRatePeriod.count" ] do
      post loans_path, params: {
        account: {
          name: "Invalid Annuity Mortgage",
          balance: 300000,
          currency: "USD",
          accountable_type: "Loan",
          accountable_attributes: {
            subtype: "mortgage",
            annuity_enabled: "1",
            started_on: "2024-01-01",
            payment_cadence: "monthly",
            term_months: 360,
            initial_balance: 300000,
            loan_rate_periods_attributes: {
              "0" => { starts_on: "2024-01-01", annual_rate: "-1.0" }
            }
          }
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "reconciles annuity loan to scheduled balance" do
    @account.update!(balance: 250000)
    @account.loan.loan_rate_periods.create!(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account.loan.update!(
      annuity_enabled: true,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      initial_balance: 300000,
      term_months: 360
    )

    assert_difference -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post reconcile_loan_path(@account)
    end

    reconciliation_entry = @account.entries.valuations.order(:created_at).last
    scheduled_balance = @account.loan.amortization_schedule.scheduled_balance

    assert_in_delta scheduled_balance, reconciliation_entry.amount, 0.01
    assert_redirected_to account_path(@account)
    assert_equal "Loan reconciled to scheduled balance", flash[:notice]
  end

  test "loan overview displays annuity schedule summary and payment breakdown" do
    @account.update!(balance: 299701.35)
    @account.loan.loan_rate_periods.create!(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account.loan.update!(
      annuity_enabled: true,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      initial_balance: 300000,
      term_months: 360
    )

    travel_to Date.new(2024, 2, 1) do
      get account_path(@account)
    end

    assert_response :success
    assert_select "div", text: /Scheduled Balance/
    assert_select "div", text: /Balance Variance/
    assert_select "div", text: /Remaining Term/
    assert_select "h3", text: "Payment Breakdown"
    assert_select "div", text: /Interest/
    assert_select "div", text: /Principal/
  end
end
