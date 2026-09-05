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

  test "persists interest accrual settings through the shared update action" do
    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          interest_rate: 6,
          accrue_interest: "1",
          interest_accrual_start_date: "2026-01-01",
          interest_accrual_day: 15
        }
      }
    }

    loan = @account.reload.accountable
    assert loan.accrue_interest?
    assert_equal Date.new(2026, 1, 1), loan.interest_accrual_start_date
    assert_equal 15, loan.interest_accrual_day

    # And back off again — the DS::Toggle's paired hidden field sends "0".
    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        accountable_type: "Loan",
        accountable_attributes: { id: @account.accountable_id, accrue_interest: "0" }
      }
    }

    assert_not @account.reload.accountable.accrue_interest?
  end

  test "persists rate changes through the shared update action" do
    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          interest_rate: 6,
          accrue_interest: "1",
          interest_accrual_start_date: "2026-01-01",
          rate_changes_attributes: {
            "0" => { effective_date: "2026-06-01", rate: 9 }
          }
        }
      }
    }

    rate_change = @account.reload.accountable.rate_changes.sole
    assert_equal Date.new(2026, 6, 1), rate_change.effective_date
    assert_equal 9, rate_change.rate

    # And remove it again via the _destroy flag the row's remove button sets.
    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          rate_changes_attributes: {
            "0" => { id: rate_change.id, _destroy: "1" }
          }
        }
      }
    }

    assert_empty @account.reload.accountable.rate_changes
  end

  test "rejects enabling accrual without the inputs it needs" do
    patch loan_path(@account), params: {
      account: {
        name: @account.name,
        accountable_type: "Loan",
        accountable_attributes: {
          id: @account.accountable_id,
          accrue_interest: "1",
          interest_rate: "",
          interest_accrual_start_date: ""
        }
      }
    }

    assert_response :unprocessable_entity
    assert_not @account.reload.accountable.accrue_interest?
  end

  test "shows the accrual toggle only for unlinked loans" do
    get edit_account_url(@account)
    assert_response :success
    assert_select "input[name=?]", "account[accountable_attributes][accrue_interest]"

    Account.any_instance.stubs(:unlinked?).returns(false)

    get edit_account_url(@account)
    assert_response :success
    assert_select "input[name=?]", "account[accountable_attributes][accrue_interest]", count: 0
  end
end
