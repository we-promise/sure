require "test_helper"

class Provider::SophtronIngestionTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Sophtron.new("family-user", Base64.strict_encode64("secret-key"))
  end

  test "account RPC retains exact decimals and unmodified provider evidence" do
    stub_request(:post, "https://api.sophtron.com/api/UserInstitution/GetUserInstitutionAccounts")
      .with(body: { UserInstitutionID: "institution-1" }.to_json)
      .to_return(status: 200, body: '[{"AccountID":"account-1","AccountBalance":123.456789012345678901}]')
    result = @client.get_ingestion_accounts("institution-1")
    assert_equal BigDecimal("123.456789012345678901"), result[:items].first[:AccountBalance]
    assert_equal result[:items], result[:evidence]
    assert_nil result[:next_cursor]
  end

  test "transactions RPC uses bounded dates and existing signing scheme" do
    path = "/Transaction/GetTransactionsByTransactionDate"
    stub_request(:post, "https://api.sophtron.com/api#{path}")
      .with(headers: { Authorization: @client.auth_header_for(:post, path) },
        body: { AccountID: "account-1", StartDate: "2026-09-01", EndDate: "2026-09-14" }.to_json)
      .to_return(status: 200, body: '{"Transactions":[{"TransactionID":"tx-1","Amount":-0.000000000000000001}]}')
    result = @client.get_ingestion_transactions("account-1", start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 14))
    assert_equal BigDecimal("-0.000000000000000001"), result[:items].first[:Amount]
  end

  test "missing collections and explicit partial results cannot complete" do
    [ "", "{}", '{"Accounts":null}', '{"Accounts":[],"TotalCount":5}', '{"Accounts":[],"NextCursor":"next"}' ].each do |body|
      stub_request(:post, "https://api.sophtron.com/api/UserInstitution/GetUserInstitutionAccounts").to_return(status: 200, body: body)
      assert_raises(Provider::Sophtron::Error) { @client.get_ingestion_accounts("institution-1") }
    end
  end

  test "private response bodies never enter native error messages or details" do
    [ 400, 401, 403, 429, 500 ].each do |status|
      stub_request(:post, "https://api.sophtron.com/api/UserInstitution/GetUserInstitutionAccounts").to_return(status: status, body: "private-account-information")
      error = assert_raises(Provider::Sophtron::Error) { @client.get_ingestion_accounts("institution-1") }
      refute_includes error.message, "private-account-information"
      assert_nil error.details
      assert_nil error.cause
    end
  end

  test "unsupported cursors and reversed windows make no request" do
    assert_raises(Provider::Sophtron::Error) { @client.get_ingestion_accounts("institution-1", cursor: "invented-page") }
    assert_raises(Provider::Sophtron::Error) do
      @client.get_ingestion_transactions("account-1", start_date: Date.new(2026, 9, 14), end_date: Date.new(2026, 9, 1))
    end
  end

  test "native transport rejects unsafe configured endpoint schemes" do
    client = Provider::Sophtron.new("family-user", Base64.strict_encode64("secret-key"), base_url: "http://example.test/api")
    assert_raises(Provider::Sophtron::Error) { client.get_ingestion_accounts("institution-1") }
  end
end
