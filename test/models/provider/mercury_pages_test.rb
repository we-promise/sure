require "test_helper"

class Provider::MercuryPagesTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Mercury.new("test-token")
  end

  test "account pages retain exact JSON decimals and follow account IDs" do
    stub_request(:get, "https://api.mercury.com/api/v1/accounts")
      .with(query: { limit: 1, order: "asc" }, headers: { "Authorization" => "Bearer test-token" })
      .to_return(status: 200, body: '{"accounts":[{"id":"account-1","currentBalance":123.456789012345678901}]}')
    first = @client.get_accounts_page(limit: 1)

    assert_equal BigDecimal("123.456789012345678901"), first[:items].first[:currentBalance]
    assert_equal "account-1", first[:next_cursor]
    stub_request(:get, "https://api.mercury.com/api/v1/accounts")
      .with(query: { limit: 1, order: "asc", start_after: "account-1" })
      .to_return(status: 200, body: '{"accounts":[]}')
    assert_nil @client.get_accounts_page(cursor: first[:next_cursor], limit: 1)[:next_cursor]
  end

  test "transaction pages use offset totals and retain ISO window precision" do
    stub_request(:get, "https://api.mercury.com/api/v1/account/account-1/transactions")
      .with(query: { start: "2026-01-01T12:30:00Z", end: "2026-02-01T10:15:00Z", offset: 0, limit: 1, order: "asc" })
      .to_return(status: 200, body: '{"transactions":[{"id":"tx-1","amount":-0.1234567890123456789}],"total":2}')
    first = @client.get_account_transactions_page("account-1", start_date: "2026-01-01T12:30:00Z", end_date: "2026-02-01T10:15:00Z", limit: 1)

    assert_equal BigDecimal("-0.1234567890123456789"), first[:items].first[:amount]
    assert_equal "1", first[:next_cursor]
    stub_request(:get, "https://api.mercury.com/api/v1/account/account-1/transactions")
      .with(query: { offset: 1, limit: 1, order: "asc" })
      .to_return(status: 200, body: '{"transactions":[{"id":"tx-2"}],"total":2}')
    assert_nil @client.get_account_transactions_page("account-1", cursor: first[:next_cursor], limit: 1)[:next_cursor]
  end

  test "a short page with remaining total is still incomplete" do
    stub_request(:get, "https://api.mercury.com/api/v1/account/account-1/transactions")
      .with(query: { offset: 0, limit: 1000, order: "asc" })
      .to_return(status: 200, body: '{"transactions":[{"id":"tx-1"}],"total":10}')

    assert_equal "1", @client.get_account_transactions_page("account-1")[:next_cursor]
  end

  test "missing collections and inconsistent totals fail instead of completing empty" do
    [ '{}', '{"transactions":null}', '{"transactions":[],"total":3}', '{"transactions":[{"id":"id"}],"total":0}', '{"transactions":[],"total":"0"}' ].each do |body|
      stub_request(:get, "https://api.mercury.com/api/v1/account/account-1/transactions")
        .with(query: { offset: 0, limit: 1000, order: "asc" }).to_return(status: 200, body: body)
      error = assert_raises(Provider::Mercury::MercuryError) { @client.get_account_transactions_page("account-1") }
      assert_equal :invalid_response, error.error_type
    end
  end

  test "new ingestion reads do not expose unsuccessful provider response bodies" do
    { 401 => :unauthorized, 403 => :access_forbidden, 429 => :rate_limited, 500 => :fetch_failed }.each do |status, type|
      stub_request(:get, "https://api.mercury.com/api/v1/accounts")
        .with(query: { limit: 1000, order: "asc" }).to_return(status: status, body: "private-provider-body")
      error = assert_raises(Provider::Mercury::MercuryError) { @client.get_accounts_page }
      assert_equal type, error.error_type
      refute_includes error.message, "private-provider-body"
      assert_nil error.cause
    end
  end

  test "invalid cursors and limits cannot become coerced network parameters" do
    [ "-1", "1.5", "1&limit=99999", "https://private.example", 12 ].each do |cursor|
      assert_raises(Provider::Mercury::MercuryError) { @client.get_account_transactions_page("account-1", cursor: cursor) }
    end
    [ 0, 1001, "100" ].each do |limit|
      assert_raises(Provider::Mercury::MercuryError) { @client.get_accounts_page(limit: limit) }
    end
  end
end
