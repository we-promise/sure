require "test_helper"

class BondsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:bond)
  end

  test "creates with bond details" do
    assert_difference -> { Account.count } => 1,
      -> { Bond.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post bonds_path, params: {
        account: {
          name: "New Treasury Bill",
          balance: 20000,
          currency: "USD",
          institution_name: "TreasuryDirect",
          institution_domain: "treasurydirect.gov",
          notes: "4-week bill",
          accountable_type: "Bond",
          accountable_attributes: {
            initial_balance: 20000,
            tax_wrapper: "ike",
            auto_buy_new_issues: true
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Treasury Bill", created_account.name
    assert_equal 20000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "TreasuryDirect", created_account[:institution_name]
    assert_equal "treasurydirect.gov", created_account[:institution_domain]
    assert_equal "4-week bill", created_account[:notes]
    assert_equal 20000, created_account.accountable.initial_balance
    assert_equal "ike", created_account.accountable.tax_wrapper
    assert created_account.accountable.auto_buy_new_issues?

    assert_redirected_to created_account
    assert_equal "Bond account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with bond details" do
    assert_no_difference [ "Account.count", "Bond.count" ] do
      patch bond_path(@account), params: {
        account: {
          name: "Updated Bond",
          balance: 10000,
          currency: "USD",
          institution_name: "Broker",
          institution_domain: "broker.example",
          notes: "Updated bond notes",
          accountable_type: "Bond",
          accountable_attributes: {
            id: @account.accountable_id,
            initial_balance: 19000,
            tax_wrapper: "ikze",
            auto_buy_new_issues: true
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Bond", @account.name
    assert_equal 10000, @account.balance
    assert_equal "Broker", @account[:institution_name]
    assert_equal "broker.example", @account[:institution_domain]
    assert_equal "Updated bond notes", @account[:notes]
    assert_equal 19000, @account.accountable.initial_balance
    assert_equal "ikze", @account.accountable.tax_wrapper
    assert @account.accountable.auto_buy_new_issues?

    assert_redirected_to @account
    assert_equal "Bond account updated", flash[:notice]
  end
end
