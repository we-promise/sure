require "test_helper"

class Provider::SophtronTest < ActiveSupport::TestCase
  setup do
    @access_key = Base64.strict_encode64("secret-key")
    @provider = Provider::Sophtron.new("developer-user", @access_key)
  end

  test "builds FIApiAUTH header from last path segment only" do
    auth_header = @provider.auth_header_for("POST", "/api/UserInstitution/CreateUserInstitution")
    expected_auth_path = "/createuserinstitution"
    expected_signature = Base64.strict_encode64(
      OpenSSL::HMAC.digest(
        OpenSSL::Digest.new("sha256"),
        "secret-key",
        "POST\n#{expected_auth_path}"
      )
    )

    assert_equal "FIApiAUTH:developer-user:#{expected_signature}:#{expected_auth_path}", auth_header
  end

  test "lists v2 customers" do
    stub_request(:get, "https://api.sophtron.com/api/v2/customers")
      .to_return(status: 200, body: [ { CustomerID: "cust-1", CustomerName: "Sure family 1" } ].to_json)

    customers = provider_data(@provider.list_customers)

    assert_equal 1, customers.length
    assert_equal "cust-1", customers.first[:CustomerID]
  end

  test "creates customer with documented body" do
    stub_request(:post, "https://api.sophtron.com/api/v2/customers")
      .with(body: { UniqueID: "sure-family-1", Name: "Sure family 1", Source: "Sure" }.to_json)
      .to_return(status: 200, body: { CustomerID: "cust-1", CustomerName: "Sure family 1" }.to_json)

    customer = provider_data(@provider.create_customer(unique_id: "sure-family-1", name: "Sure family 1", source: "Sure"))

    assert_equal "cust-1", customer[:CustomerID]
  end

  test "health check auth accepts empty success body" do
    stub_request(:get, "https://api.sophtron.com/api/Institution/HealthCheckAuth")
      .to_return(status: 200, body: "")

    assert_equal({}, provider_data(@provider.health_check_auth))
  end

  test "health check auth accepts non json success body" do
    stub_request(:get, "https://api.sophtron.com/api/Institution/HealthCheckAuth")
      .to_return(status: 200, body: "OK")

    assert_equal "OK", provider_data(@provider.health_check_auth)
  end

  test "creates user institution with documented V1 body" do
    stub_request(:post, "https://api.sophtron.com/api/UserInstitution/CreateUserInstitution")
      .with(body: {
        UserID: "developer-user",
        InstitutionID: "inst-1",
        UserName: "bank-user",
        Password: "bank-pass",
        PIN: ""
      }.to_json)
      .to_return(status: 200, body: { JobID: "job-1", UserInstitutionID: "ui-1" }.to_json)

    response = provider_data(@provider.create_user_institution(
      institution_id: "inst-1",
      username: "bank-user",
      password: "bank-pass"
    ))

    assert_equal "job-1", response[:JobID]
    assert_equal "ui-1", response[:UserInstitutionID]
  end

  test "classifies Sophtron timeout job as failed" do
    job = {
      SuccessFlag: false,
      LastStep: "LogInPanel",
      LastStatus: "Timeout"
    }

    assert Provider::Sophtron.job_failed?(job)
  end

  test "classifies completed job without failure flag as completed" do
    job = {
      LastStep: "TokenInput",
      LastStatus: "Completed"
    }

    assert Provider::Sophtron.job_completed?(job)
    assert_not Provider::Sophtron.job_failed?(job)
  end

  test "does not classify completed job with failure flag as completed" do
    job = {
      SuccessFlag: false,
      LastStep: "LogInPanel",
      LastStatus: "Completed"
    }

    assert Provider::Sophtron.job_failed?(job)
    assert_not Provider::Sophtron.job_completed?(job)
  end

  test "classifies token input prompt as requiring input" do
    job = {
      TokenInputName: "Token",
      LastStep: "TokenInput",
      LastStatus: "Started"
    }

    assert Provider::Sophtron.job_requires_input?(job)
  end

  test "does not classify submitted token as requiring input" do
    job = {
      TokenInputName: "Token",
      TokenInput: "123456",
      LastStep: "TokenInput",
      LastStatus: "Started"
    }

    assert_not Provider::Sophtron.job_requires_input?(job)
  end

  test "submits security answers as JSON array string" do
    stub_request(:post, "https://api.sophtron.com/api/Job/UpdateJobSecurityAnswer")
      .with(body: { JobID: "job-1", SecurityAnswer: [ "blue" ].to_json }.to_json)
      .to_return(status: 200, body: "")

    assert_equal({}, provider_data(@provider.update_job_security_answer("job-1", [ "blue" ])))
  end

  test "fetches transactions by transaction date with documented body" do
    stub_request(:post, "https://api.sophtron.com/api/Transaction/GetTransactionsByTransactionDate")
      .with(body: {
        AccountID: "acct-1",
        StartDate: "2026-01-01",
        EndDate: "2026-02-01"
      }.to_json)
      .to_return(status: 200, body: [
        {
          TransactionID: "tx-1",
          Amount: "-12.34",
          TransactionDate: "2026-01-15",
          Description: "CHECKCARD 1234 Coffee Shop NY"
        }
      ].to_json)

    result = provider_data(@provider.get_account_transactions("acct-1", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 2, 1)))
    transaction = result[:transactions].first

    assert_equal "tx-1", transaction[:id]
    assert_equal "acct-1", transaction[:accountId]
    assert_equal "-12.34", transaction[:amount]
    assert_equal "2026-01-15", transaction[:date]
  end

  test "normalizes TransactionId transaction identifiers" do
    stub_request(:post, "https://api.sophtron.com/api/Transaction/GetTransactionsByTransactionDate")
      .to_return(status: 200, body: [
        {
          TransactionId: "tx-1",
          Amount: "-12.34",
          TransactionDate: "2026-01-15",
          Description: "CHECKCARD 1234 Coffee Shop NY"
        }
      ].to_json)

    result = provider_data(@provider.get_account_transactions("acct-1", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 2, 1)))

    assert_equal "tx-1", result[:transactions].first[:id]
  end

  test "maps user institution accounts from V1 fields" do
    stub_request(:post, "https://api.sophtron.com/api/UserInstitution/GetUserInstitutionAccounts")
      .with(body: { UserInstitutionID: "ui-1" }.to_json)
      .to_return(status: 200, body: [
        {
          AccountID: "acct-1",
          AccountName: "Checking",
          AccountType: "checking",
          AccountBalance: "123.45",
          AccountNumber: "00001234"
        }
      ].to_json)

    result = provider_data(@provider.get_accounts("ui-1"))
    account = result[:accounts].first

    assert_equal "acct-1", account[:account_id]
    assert_equal "Checking", account[:account_name]
    assert_equal "123.45", account[:balance]
    assert_equal "****1234", account[:account_number_mask]
  end

  test "empty success body parses as empty hash" do
    stub_request(:post, "https://api.sophtron.com/api/Job/UpdateJobCaptcha")
      .to_return(status: 200, body: "")

    assert_equal({}, provider_data(@provider.update_job_captcha("job-1", "abc123")))
  end

  test "raises typed error on unauthorized response" do
    stub_request(:get, "https://api.sophtron.com/api/Institution/HealthCheckAuth")
      .to_return(status: 401, body: "bad auth")

    response = @provider.health_check_auth

    assert_not response.success?
    assert_instance_of Provider::Sophtron::Error, response.error
    assert_equal :unauthorized, response.error.error_type
  end

  private

    def provider_data(response)
      assert response.success?
      response.data
    end
end
