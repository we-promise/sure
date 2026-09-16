require "test_helper"

class Provider::BrexPagesTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Brex.new("test-token")
  end

  test "new cash inventory API performs one request and exposes opaque continuation" do
    stub_request(:get, "https://api.brex.com/v2/accounts/cash")
      .with(query: { limit: 1000, cursor: "input-cursor" }, headers: { "Authorization" => "Bearer test-token" })
      .to_return(status: 200, body: { items: [ { id: "cash-1", current_balance: { amount: 9_007_199_254_740_993, currency: "USD" } } ], next_cursor: "next-cursor" }.to_json)

    page = @client.get_cash_accounts_page(cursor: "input-cursor")
    assert_equal "next-cursor", page[:next_cursor]
    assert_equal 9_007_199_254_740_993, page[:items].first[:current_balance][:amount]
  end

  test "card account array responses are explicitly complete" do
    stub_request(:get, "https://api.brex.com/v2/accounts/card")
      .with(query: { limit: 1000 }).to_return(status: 200, body: [ { id: "physical-card" } ].to_json)

    page = @client.get_card_accounts_page
    assert_equal "physical-card", page[:items].first[:id]
    assert_nil page[:next_cursor]
  end

  test "cash and primary-card transaction methods preserve posted start and cursor" do
    stub_request(:get, "https://api.brex.com/v2/transactions/cash/cash-1")
      .with(query: { posted_at_start: "2026-01-02T00:00:00Z", limit: 1000, cursor: "cash-cursor" })
      .to_return(status: 200, body: '{"items":[],"next_cursor":null}')
    stub_request(:get, "https://api.brex.com/v2/transactions/card/primary")
      .with(query: { posted_at_start: "2026-01-02T00:00:00Z", limit: 1000 })
      .to_return(status: 200, body: '{"items":[],"next_cursor":null}')

    assert_empty @client.get_cash_transactions_page("cash-1", cursor: "cash-cursor", start_date: Date.new(2026, 1, 2))[:items]
    assert_empty @client.get_primary_card_transactions_page(start_date: "2026-01-02T00:00:00Z")[:items]
  end

  test "unknown envelopes missing collections and repeated continuations fail" do
    [ {}, { items: nil }, { items: [], data: [] }, { items: [ "invalid" ] }, { items: [], next_cursor: "" }, { items: [], next_cursor: "same-cursor" } ].each do |body|
      stub_request(:get, "https://api.brex.com/v2/accounts/cash")
        .with(query: { limit: 1000, cursor: "same-cursor" }).to_return(status: 200, body: body.to_json)
      error = assert_raises(Provider::Brex::BrexError) { @client.get_cash_accounts_page(cursor: "same-cursor") }
      assert_equal :invalid_response, error.error_type
    end
  end

  test "native page failures preserve retry classification without raw financial data" do
    stub_request(:get, "https://api.brex.com/v2/accounts/card")
      .with(query: { limit: 1000 }).to_return(status: 429, body: "private-provider-body", headers: { "X-Brex-Trace-Id" => "trace-id" })

    error = assert_raises(Provider::Brex::BrexError) { @client.get_card_accounts_page }
    assert_equal :rate_limited, error.error_type
    assert_equal "trace-id", error.trace_id
    refute_includes error.message, "private-provider-body"
  end
end
