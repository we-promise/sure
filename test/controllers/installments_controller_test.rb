require "test_helper"

class InstallmentsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:installment)
  end

  test "creates with installment details" do
    assert_difference -> { Account.count } => 1,
      -> { Installment.count } => 1 do
      post installments_path, params: {
        account: {
          name: "New Installment",
          currency: "USD",
          accountable_type: "Installment",
          accountable_attributes: {
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
    assert_equal 2, created_account.accountable.current_term
    assert_equal "monthly", created_account.accountable.payment_period
    # Balance is calculated by Creator based on payments_scheduled_to_date (1 payment on today)
    # remaining = total_term - payments_scheduled = 6 - 1 = 5, balance = 5 * 200 = 1000
    assert_equal 1000, created_account.balance

    assert_redirected_to created_account
    assert_equal "Installment account created", flash[:notice]
  end

  test "updates with installment details" do
    assert_no_difference [ "Account.count", "Installment.count" ] do
      patch installment_path(@account), params: {
        account: {
          name: "Updated Installment",
          currency: "USD",
          accountable_type: "Installment",
          source_account_id: accounts(:depository).id,
          accountable_attributes: {
            id: @account.accountable_id,
            installment_cost: 250,
            total_term: 10,
            current_term: 3,
            payment_period: "monthly",
            first_payment_date: Date.current.to_s
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Installment", @account.name
    assert_equal 3, @account.accountable.current_term
    assert_equal 250, @account.accountable.installment_cost
    assert RecurringTransaction.find_by(installment_id: @account.accountable.id)

    assert_redirected_to @account
    assert_equal "Installment account updated", flash[:notice]
  end

  test "updating only account name does not regenerate activity" do
    source_account = accounts(:depository)
    installment = @account.accountable

    # Create the installment activity with a source account so recurring transaction is created
    Installment::Creator.new(installment, source_account_id: source_account.id).call
    initial_recurring_transaction = RecurringTransaction.find_by(installment_id: installment.id)
    assert initial_recurring_transaction, "Should have created a recurring transaction"

    # Update only the account name (same installment values)
    assert_no_difference "RecurringTransaction.count" do
      patch installment_path(@account), params: {
        account: {
          name: "Renamed Installment Account",
          currency: "USD",
          accountable_attributes: {
            id: installment.id,
            installment_cost: installment.installment_cost,
            total_term: installment.total_term,
            current_term: installment.current_term,
            payment_period: installment.payment_period,
            first_payment_date: installment.first_payment_date.to_s
          }
        }
      }
    end

    @account.reload

    assert_equal "Renamed Installment Account", @account.name
    # Verify the same recurring transaction still exists (not deleted and recreated)
    assert_equal initial_recurring_transaction.id, RecurringTransaction.find_by(installment_id: installment.id).id

    assert_redirected_to @account
    assert_equal "Installment account updated", flash[:notice]
  end
end
