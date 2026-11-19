require "test_helper"

class EquityGrantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:investment)
    @account.investment.update!(subtype: "stock_plan")
  end

  test "adds a grant and a repeating vest schedule" do
    post account_equity_grants_url(@account), params: { equity_grant: { ticker: "ACME", grant_identifier: "RS1", grant_date: "2025-03-01", total_units: "240", grant_type: "rsu" } }
    grant = @account.equity_grants.find_by!(grant_identifier: "RS1")

    post account_equity_vests_url(@account), params: { equity_vest: { equity_grant_id: grant.id, vest_date: "2026-03-15", units: "20", every_months: "3", count: "4" } }

    assert_equal [ Date.new(2026, 3, 15), Date.new(2026, 6, 15), Date.new(2026, 9, 15), Date.new(2026, 12, 15) ], grant.vests.reload.map(&:vest_date)
    assert_redirected_to account_url(@account, tab: "grants")
  end

  test "adding a vest on a date that has one keeps the existing details" do
    grant = @account.equity_grants.create!(ticker: "ACME")
    grant.vests.create!(vest_date: Date.new(2026, 3, 15), units: 60, units_withheld: 25, net_proceeds: 5000, source: "csv")

    post account_equity_vests_url(@account), params: { equity_vest: { equity_grant_id: grant.id, vest_date: "2026-03-15", units: "10" } }

    vest = grant.vests.reload.sole
    assert_equal [ 60, 25, 5000, "csv" ], [ vest.units, vest.units_withheld, vest.net_proceeds, vest.source ]
  end

  test "forfeits a grant's remaining units" do
    grant = @account.equity_grants.create!(ticker: "ACME")

    post forfeit_equity_grant_url(grant)

    assert_equal Date.current, grant.reload.forfeited_on
  end

  test "only stock plan accounts have a grants tab" do
    get account_url(@account, tab: "grants")
    assert_select "[data-testid='grants-tab']"

    @account.investment.update!(subtype: "brokerage")
    get account_url(@account)
    assert_select "[data-testid='grants-tab']", count: 0
  end

  test "the grants tab lists upcoming and past vests" do
    grant = @account.equity_grants.create!(ticker: "ACME", grant_identifier: "RS1")
    grant.vests.create!(vest_date: Date.current + 30, units: 10)
    grant.vests.create!(vest_date: Date.current - 30, units: 12, net_proceeds: 1500)

    get account_url(@account, tab: "grants")

    assert_response :success
    assert_select "[data-testid='grants-tab']", text: /RS1/
  end

  test "imports vests from a CSV" do
    file = uploaded_file(filename: "vests.csv", content_type: "text/csv", content: "grant_id,vest_date,units\nRS1,2026-03-15,60\n")

    post import_account_equity_grants_url(@account), params: { file: file, ticker: "ACME" }

    assert_equal 1, @account.equity_grants.count
  end

  test "uploads documents and queues them when PDF import is available" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    file = uploaded_file(filename: "grant.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%example\n")

    assert_enqueued_with(job: EquityGrantDocumentReadJob) do
      post upload_account_equity_grants_url(@account), params: { files: [ file ] }
    end
  end

  test "a document already uploaded to another account is reported" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    content = "%PDF-1.4\n%elsewhere\n"
    AccountStatement.create_from_upload!(family: @account.family, account: accounts(:depository),
                                         file: uploaded_file(filename: "grant.pdf", content_type: "application/pdf", content: content))

    assert_no_enqueued_jobs(only: EquityGrantDocumentReadJob) do
      post upload_account_equity_grants_url(@account), params: { files: [ uploaded_file(filename: "grant.pdf", content_type: "application/pdf", content: content) ] }
    end
    assert_match "Already uploaded to another account, so not read here: grant.pdf", flash[:notice]
  end

  test "uploading is refused when PDF import isn't available" do
    Ai.stubs(:availability).returns(Ai::Availability.unavailable(:extract_pdf, :not_configured))
    file = uploaded_file(filename: "grant.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%example\n")

    assert_no_enqueued_jobs(only: EquityGrantDocumentReadJob) do
      post upload_account_equity_grants_url(@account), params: { files: [ file ] }
    end
  end

  test "reading uploaded documents skips ones already read" do
    Ai.stubs(:availability).returns(Ai::Availability.available(:extract_pdf))
    read = AccountStatement.create_from_upload!(family: @account.family, account: @account,
                                                file: uploaded_file(filename: "a.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%a\n"))
    read.update_columns(equity_grants_read_at: Time.current)
    AccountStatement.create_from_upload!(family: @account.family, account: @account,
                                         file: uploaded_file(filename: "b.pdf", content_type: "application/pdf", content: "%PDF-1.4\n%b\n"))

    assert_enqueued_jobs(1, only: EquityGrantDocumentReadJob) do
      post read_statements_account_equity_grants_url(@account)
    end
  end

  test "deletes a grant with its vests" do
    grant = @account.equity_grants.create!(ticker: "ACME")
    grant.vests.create!(vest_date: Date.current, units: 1)

    assert_difference [ "EquityGrant.count", "EquityVest.count" ], -1 do
      delete equity_grant_url(grant)
    end
  end
end
