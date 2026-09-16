require "test_helper"
require "ostruct"

class Provider::RedbarkSnapshotTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Redbark.new(api_key: "private-api-key")
  end

  test "native transport reads one exact decimal page and retains the truncation evidence" do
    Provider::Redbark.expects(:get).once.with("https://api.redbark.com/v1/accounts", headers: auth_headers,
      query: { limit: 200, offset: 200 }).returns(response(
        '{"data":[{"id":"account","precise":123456789.123456789012345678}],"pagination":{"hasMore":true}}',
        headers: { "x-redbark-truncated" => "true" }))

    result = @provider.list_accounts_page(offset: 200)

    assert_equal BigDecimal("123456789.123456789012345678"), result.fetch("response").fetch("data").sole.fetch("precise")
    assert_equal "true", result.fetch("pagination_headers").fetch("x-redbark-truncated")
  end

  test "transaction requests use explicit scope and omit disabled pending" do
    Provider::Redbark.expects(:get).with("https://api.redbark.com/v1/transactions", headers: auth_headers,
      query: { connectionId: "connection/1", accountId: "account&1", from: "2026-01-01", to: "2026-01-31", limit: 500, offset: 500 })
      .returns(response('{"data":[],"pagination":{"hasMore":false}}'))
    @provider.get_transactions_page(connection_id: "connection/1", account_id: "account&1",
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), include_pending: false, offset: 500)
  end

  test "pending request and bounded account balance request preserve their endpoint parameters" do
    Provider::Redbark.expects(:get).with("https://api.redbark.com/v1/transactions", headers: auth_headers,
      query: { connectionId: "connection", accountId: "account", from: "2026-01-01", to: "2026-01-31",
        includePending: "true", limit: 500, offset: 0 }).returns(response('{"data":[],"pagination":{"hasMore":false}}'))
    @provider.get_transactions_page(connection_id: "connection", account_id: "account",
      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), include_pending: true)
    Provider::Redbark.expects(:get).with("https://api.redbark.com/v1/balances", headers: auth_headers,
      query: { accountIds: "account" }).returns(response('{"data":[]}'))
    assert_equal [], @provider.get_balances_snapshot(account_ids: [ "account" ]).fetch("response").fetch("data")
    assert_raises(ArgumentError) { @provider.get_balances_snapshot(account_ids: [ "account,other" ]) }
    assert_raises(ArgumentError) { @provider.list_accounts_page(offset: -1) }
  end

  test "invalid JSON and provider error bodies never enter exception messages or causes" do
    Provider::Redbark.expects(:get).returns(response('private-api-key malformed {'))
    error = assert_raises(Provider::Redbark::Error) { @provider.list_accounts_page }
    assert_equal :invalid_response, error.error_type
    refute_includes error.message, "private-api-key"
    assert_nil error.cause
    Provider::Redbark.expects(:get).returns(response('{"error":{"message":"private-api-key"}}', code: 400))
    error = assert_raises(Provider::Redbark::Error) { @provider.list_accounts_page }
    assert_equal :bad_request, error.error_type
    refute_includes error.message, "private-api-key"
    assert_nil error.cause
  end

  test "exhausted network retries preserve classification without logging remote private details" do
    @provider.stubs(:sleep)
    Rails.logger.expects(:warn).times(3).with { |message| !message.include?("private-api-key") }
    Rails.logger.expects(:error).once.with { |message| !message.include?("private-api-key") }
    Provider::Redbark.expects(:get).times(4).raises(SocketError, "private-api-key remote details")

    error = assert_raises(Provider::Redbark::Error) { @provider.list_accounts_page }

    assert_equal :network_error, error.error_type
    refute_includes error.message, "private-api-key"
    assert_nil error.cause
  end

  private
    def auth_headers
      { "Authorization" => "Bearer private-api-key", "Content-Type" => "application/json", "Accept" => "application/json" }
    end

    def response(body, code: 200, headers: {})
      OpenStruct.new(code: code, body: body, headers: headers)
    end
end
