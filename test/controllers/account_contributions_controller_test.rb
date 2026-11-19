require "test_helper"

class AccountContributionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
    @account.investment.update!(subtype: "401k")
  end

  test "adds a contribution" do
    assert_difference "@account.account_contributions.count", 1 do
      post account_account_contributions_url(@account), params: { account_contribution: { date: "2025-01-15", amount: "500", kind: "contribution", description: "Payroll" } }
    end

    assert_redirected_to account_url(@account, tab: "contributions")
    assert @account.account_contributions.last.from_manual?
  end

  test "imports a CSV" do
    file = uploaded_file(filename: "contributions.csv", content_type: "text/csv", content: "date,amount,kind\n2025-01-15,500,contribution\n")

    assert_difference "@account.account_contributions.count", 1 do
      post import_account_account_contributions_url(@account), params: { file: file }
    end
    assert_redirected_to account_url(@account, tab: "contributions")
  end

  test "uploads statements and queues them to be read" do
    AccountStatement::InvestmentDataReader.stubs(:available?).returns(true)
    file = uploaded_file(filename: "q1.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%fake\n")

    assert_enqueued_with(job: InvestmentDocumentReadJob) do
      assert_difference "@account.account_statements.count", 1 do
        post upload_account_account_contributions_url(@account), params: { files: [ file ] }
      end
    end
  end

  test "deletes a contribution" do
    contribution = @account.account_contributions.create!(date: Date.current, amount: 100, kind: "contribution")

    assert_difference "AccountContribution.count", -1 do
      delete account_contribution_url(contribution)
    end
  end

  test "a read-only member cannot add contributions" do
    sign_in users(:family_member)
    @account.account_shares.destroy_all
    @account.account_shares.create!(user: users(:family_member), permission: "read_only")

    assert_no_difference "AccountContribution.count" do
      post account_account_contributions_url(@account), params: { account_contribution: { date: "2025-01-15", amount: "500", kind: "contribution" } }
    end
  end

  test "a taxable brokerage account has no contributions tab" do
    @account.investment.update!(subtype: "brokerage")

    get account_url(@account)

    assert_select "[data-testid='principal-tab']", count: 0
  end

  test "the account page shows what was contributed and the growth" do
    @account.account_contributions.create!(date: Date.new(2025, 1, 1), amount: 4000, kind: "contribution")

    get account_url(@account, tab: "contributions")

    assert_response :success
    assert_select "[data-testid='principal-tab']"
    assert_select "[data-time-series-chart-comparison-value]"
  end
end
