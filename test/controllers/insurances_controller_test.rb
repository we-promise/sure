require "test_helper"

class InsurancesControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:insurance)
  end

  test "creates with insurance details" do
    assert_difference -> { Account.count } => 1,
      -> { Insurance.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post insurances_path, params: {
        account: {
          name: "New Policy",
          balance: 12500,
          currency: "USD",
          institution_name: "Sure Insurance",
          institution_domain: "sure-insurance.example",
          notes: "Policy notes",
          accountable_type: "Insurance",
          accountable_attributes: {
            subtype: "life",
            policy_number: "POL-123",
            coverage_amount: 500000,
            premium_amount: 150,
            premium_frequency: "monthly",
            effective_date: "2026-01-01",
            expiration_date: "2036-01-01",
            renewal_date: "2027-01-01",
            insured_name: "Dylan",
            beneficiaries: "Family trust"
          }
        }
      }
    end

    created_account = Account.order(:created_at).last
    insurance = created_account.insurance

    assert_equal "New Policy", created_account.name
    assert_equal 12500, created_account.balance
    assert_equal "Insurance", created_account.accountable_type
    assert_equal "life", insurance.subtype
    assert_equal "POL-123", insurance.policy_number
    assert_equal 500000, insurance.coverage_amount
    assert_equal 150, insurance.premium_amount
    assert_equal "monthly", insurance.premium_frequency
    assert_equal Date.new(2026, 1, 1), insurance.effective_date
    assert_equal Date.new(2036, 1, 1), insurance.expiration_date
    assert_equal Date.new(2027, 1, 1), insurance.renewal_date
    assert_equal "Dylan", insurance.insured_name
    assert_equal "Family trust", insurance.beneficiaries

    assert_redirected_to created_account
    assert_equal "Insurance account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with insurance details" do
    assert_no_difference [ "Account.count", "Insurance.count" ] do
      patch insurance_path(@account), params: {
        account: {
          name: "Updated Policy",
          balance: 30000,
          currency: "USD",
          accountable_type: "Insurance",
          accountable_attributes: {
            id: @account.accountable_id,
            subtype: "umbrella",
            policy_number: "POL-456",
            coverage_amount: 1000000,
            premium_amount: 500,
            premium_frequency: "annual",
            effective_date: "2026-02-01",
            expiration_date: "2027-02-01",
            renewal_date: "2027-01-01",
            insured_name: "Dylan Family",
            beneficiaries: "Household"
          }
        }
      }
    end

    @account.reload
    insurance = @account.insurance

    assert_equal "Updated Policy", @account.name
    assert_equal 30000, @account.balance
    assert_equal "umbrella", insurance.subtype
    assert_equal "POL-456", insurance.policy_number
    assert_equal 1000000, insurance.coverage_amount
    assert_equal 500, insurance.premium_amount
    assert_equal "annual", insurance.premium_frequency
    assert_equal Date.new(2026, 2, 1), insurance.effective_date
    assert_equal Date.new(2027, 2, 1), insurance.expiration_date
    assert_equal Date.new(2027, 1, 1), insurance.renewal_date
    assert_equal "Dylan Family", insurance.insured_name
    assert_equal "Household", insurance.beneficiaries

    assert_redirected_to @account
    assert_equal "Insurance account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "shows policy overview on the account page" do
    get account_path(@account, tab: "overview")

    assert_response :success
    assert_select "main", text: /Life Insurance/
    assert_select "main", text: /LIFE-12345/
    assert_select "main", text: /Family trust/
  end
end
